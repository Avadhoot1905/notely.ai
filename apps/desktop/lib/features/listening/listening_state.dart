// Listening session state machine + live-meeting composition root.
//
// Coordinates the audio-ingestion pipeline and the transcript source behind one coherent state
// model. The data flow it wires up:
//
//   capture (mic + system) ─▶ AudioIngestion ─▶ VAD ─▶ SpeechSegmenter ─▶ [SpeechSegment]  (→ ASR seam)
//   transcript source (mock today, ASR later) ─▶ MeetingEventBus ─▶ LiveMeetingState ─▶ UI
//
// The UI projects from LiveMeetingState (via [entries]); it never touches raw audio. Persistence
// (summarise) stays downstream of the event/state layer and off the capture path.
//
//   Idle ──start──▶ Listening ──pause──▶ Paused ──resume──▶ Listening
//                      │                                         │
//                      └──────────────── stop ───────────────────┘
//                                         ▼
//                                     Reviewing ──summarise/close──▶ Idle

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/audio/audio_frame.dart';
import '../../services/audio/audio_ingestion.dart';
import '../../services/audio/meeting_audio_service.dart';
import '../../services/audio/speech_segmenter.dart';
import '../../services/meeting/live_meeting_state.dart';
import '../../services/meeting/meeting_event_bus.dart';
import '../../services/meeting/meeting_events.dart';
import '../../services/meeting/transcript_segment.dart';
import '../../services/meeting/summary_service.dart';
import '../../services/transcript/transcript_service.dart';
import '../editor/editor_state.dart';

enum ListeningState { idle, listening, paused, reviewing }

/// Immutable-ish snapshot of the active meeting session.
class MeetingSession {
  MeetingSession({required this.activeFilePath});

  /// The editor file this session will summarise into (captured at start).
  final String? activeFilePath;
}

class ListeningController extends ChangeNotifier {
  ListeningController({
    MeetingAudioService? audio,
    TranscriptService? transcript,
    SummaryService? summary,
  }) : _transcript = transcript ?? MockTranscriptService(),
       _summary = summary ?? const MockSummaryService() {
    _audio =
        audio ??
        RecordMeetingAudioService(
          onCapabilitiesChanged: _onAudioCapabilitiesChanged,
        );
    // Live Meeting State consumes the event bus; the UI observes it through this controller.
    _liveBusSub = _bus.events.listen(_live.apply);
    _live.addListener(notifyListeners);
  }

  late final MeetingAudioService _audio;
  final TranscriptService _transcript;
  final SummaryService _summary;

  // --- live-meeting event/state layer (persists across sessions; reset per meeting) ---
  final MeetingEventBus _bus = MeetingEventBus();
  final LiveMeetingStateController _live = LiveMeetingStateController();
  StreamSubscription<MeetingEvent>? _liveBusSub;

  /// The projected live-meeting state (source for UI/companion projections).
  LiveMeetingState get liveState => _live.state;

  // --- capture → ingestion → segmentation (per session) ---
  AudioIngestion? _ingestion;
  final Map<AudioSource, SpeechSegmenter> _segmenters = {};
  StreamSubscription<AudioFrame>? _framesSub;
  StreamSubscription<AudioFrame>? _ingestSub;
  int _speechSegmentCount = 0;

  /// Speech segments produced this session (ready for the ASR seam). Diagnostic.
  int get speechSegmentCount => _speechSegmentCount;

  StreamSubscription<TranscriptEvent>? _sub;

  ListeningState _state = ListeningState.idle;
  MeetingSession? _session;
  bool _summarising = false;
  String? _summariseError;
  String? _notice;
  bool _disposed = false;

  // Elapsed-capture accounting: accumulated time from finished listening spans, plus the span
  // in progress since [_runningSince]. Pausing folds the current span in; resuming reopens one.
  Duration _accumulated = Duration.zero;
  DateTime? _runningSince;

  ListeningState get state => _state;
  bool get isIdle => _state == ListeningState.idle;
  bool get isListening => _state == ListeningState.listening;
  bool get isPaused => _state == ListeningState.paused;
  bool get isReviewing => _state == ListeningState.reviewing;

  /// Total time capture has been active this session (paused time excluded).
  Duration get elapsed {
    final running = _runningSince == null
        ? Duration.zero
        : DateTime.now().difference(_runningSince!);
    return _accumulated + running;
  }

  void _foldRunningSpan() {
    if (_runningSince == null) return;
    _accumulated += DateTime.now().difference(_runningSince!);
    _runningSince = null;
  }

  /// The transcript panel is shown for any non-idle state.
  bool get showTranscript => _state != ListeningState.idle;
  bool get isSummarising => _summarising;

  /// Last summarisation failure (e.g. the engine errored or timed out), or null. The UI reads
  /// this to surface a backend error without the session crashing. Cleared on the next attempt.
  String? get summariseError => _summariseError;
  void clearSummariseError() {
    if (_summariseError == null) return;
    _summariseError = null;
    notifyListeners();
  }

  /// A calm, positive notice (not an error) — e.g. a capture was saved but AI enrichment was
  /// deferred. Shown once, then cleared. Reassures the user their data is safe.
  String? get notice => _notice;
  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// UI-facing transcript, projected from Live Meeting State (never rebuilt from raw audio).
  List<TranscriptEntry> get entries => List.unmodifiable(
    _live.state.transcript.map(
      (s) => TranscriptEntry(
        time: _fmtTime(s.start),
        speaker: s.speaker ?? '',
        text: s.text,
      ),
    ),
  );

  static String _fmtTime(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  AudioCapabilities get audioCapabilities => _audio.capabilities;

  /// Refresh the UI + publish capture health when audio capability changes.
  void _onAudioCapabilitiesChanged() {
    if (_disposed) return;
    if (!_bus.isClosed) {
      _bus.emit(AudioHealthChanged(elapsed, _audio.capabilities));
    }
    notifyListeners();
  }

  /// Begin a session tied to the currently open editor file.
  Future<void> start({String? activeFilePath}) async {
    if (_state != ListeningState.idle) return;
    _session = MeetingSession(activeFilePath: activeFilePath);
    _accumulated = Duration.zero;
    _runningSince = DateTime.now();
    _state = ListeningState.listening;
    _speechSegmentCount = 0;
    _bus.emit(MeetingStarted(Duration.zero)); // resets Live Meeting State
    notifyListeners();

    // Wire capture → ingestion → VAD → segmentation (per source). Runs for real; segments are
    // ready for the ASR seam. Does not touch the transcript path.
    _ingestion = AudioIngestion(startedAt: DateTime.now());
    _segmenters
      ..clear()
      ..[AudioSource.microphone] = SpeechSegmenter(
        source: AudioSource.microphone,
      )
      ..[AudioSource.system] = SpeechSegmenter(source: AudioSource.system);
    _framesSub = _audio.frames.listen((f) => _ingestion?.add(f));
    _ingestSub = _ingestion!.frames.listen((f) {
      final seg = _segmenters[f.source]?.add(f);
      if (seg != null) {
        _speechSegmentCount++; // → ASR seam (not transcribed yet)
      }
    });

    // Transcript source → meeting events. Today the mock emits scripted segments; a real ASR
    // consumer would emit the same TranscriptFinalized/Partial events from SpeechSegments.
    _sub = _transcript.events.listen(_onTranscriptEvent);
    await _audio.start();
    _transcript.start();
    notifyListeners();
  }

  void _onTranscriptEvent(TranscriptEvent event) {
    switch (event) {
      case TranscriptSegmentEvent(:final segment):
        final at = elapsed;
        _bus.emit(
          TranscriptFinalized(
            at,
            TranscriptSegment(
              id: 'mock-${_live.state.transcript.length}',
              start: at,
              end: at,
              source: AudioSource.system,
              speaker: segment.speaker,
              text: segment.text,
            ),
          ),
        );
      case TranscriptStarted():
      case TranscriptPausedEvent():
      case TranscriptResumedEvent():
      case TranscriptStoppedEvent():
        break;
    }
  }

  Future<void> pause() async {
    if (_state != ListeningState.listening) return;
    _foldRunningSpan();
    _state = ListeningState.paused;
    _bus.emit(MeetingPaused(elapsed));
    notifyListeners();
    await _audio.pause();
    _transcript.pause();
  }

  Future<void> resume() async {
    if (_state != ListeningState.paused) return;
    _runningSince = DateTime.now();
    _state = ListeningState.listening;
    _bus.emit(MeetingResumed(elapsed));
    notifyListeners();
    await _audio.resume();
    _transcript.resume();
  }

  /// Stop capture and enter the Review state (transcript retained in Live Meeting State).
  Future<void> stop() async {
    if (_state == ListeningState.idle || _state == ListeningState.reviewing) {
      return;
    }
    _foldRunningSpan();
    _state = ListeningState.reviewing;
    _bus.emit(MeetingStopped(elapsed));
    notifyListeners();
    _transcript.stop();
    await _audio.stop();
    await _teardownCapturePipeline();
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _teardownCapturePipeline() async {
    await _framesSub?.cancel();
    _framesSub = null;
    await _ingestSub?.cancel();
    _ingestSub = null;
    for (final s in _segmenters.values) {
      s.flush();
    }
    _segmenters.clear();
    await _ingestion?.dispose();
    _ingestion = null;
  }

  /// Summarise the session into [editor]'s open file and persist it, then close the session.
  /// If no file is open, the caller should create/open one first; this returns false so the UI
  /// can react.
  Future<bool> summarise({required EditorController editor}) async {
    if (_state != ListeningState.reviewing || _session == null) return false;
    if (!editor.hasOpenNote) return false;

    _summarising = true;
    _summariseError = null;
    notifyListeners();
    try {
      final markdown = await _summary.summarise(
        segments: entries,
        currentMarkdown: editor.text.text,
        title: null,
      );
      await editor.setContent(markdown);
    } on DeferredProcessingException catch (_) {
      // Not a failure: the engine safely persisted the transcript (the source of truth) BEFORE
      // AI ran, so the capture is saved — only enrichment is deferred. Reassure and end the
      // session; the capture waits in the Inbox and can be retried when AI is available. We never
      // lose the source, and never re-submit (which would duplicate the capture).
      _summarising = false;
      _notice = 'Saved — Notely will finish the summary when AI is available.';
      notifyListeners();
      _endSession();
      return true;
    } catch (e) {
      // A genuine failure (e.g. the engine dropped before persisting): stay in Review so the user
      // can retry or Close. We never fake a successful summary when the backend errors.
      _summariseError = _describeError(e);
      _summarising = false;
      notifyListeners();
      return false;
    }
    _summarising = false;
    _endSession();
    return true;
  }

  static String _describeError(Object e) {
    if (e is TimeoutException) {
      return 'The engine took too long to summarise this meeting.';
    }
    return 'Summarise failed: $e';
  }

  /// Discard the review and return to the normal workspace (file untouched).
  void close() {
    if (_state == ListeningState.idle) return;
    _endSession();
  }

  void _endSession() {
    _state = ListeningState.idle;
    _session = null;
    _accumulated = Duration.zero;
    _runningSince = null;
    _live.reset();
    // Fire-and-forget teardown of any lingering capture pipeline (normally torn down at stop()).
    unawaited(_teardownCapturePipeline());
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _liveBusSub?.cancel();
    _framesSub?.cancel();
    _ingestSub?.cancel();
    unawaited(_ingestion?.dispose());
    _transcript.dispose();
    _audio.dispose();
    _live.removeListener(notifyListeners);
    _live.dispose();
    unawaited(_bus.dispose());
    super.dispose();
  }
}
