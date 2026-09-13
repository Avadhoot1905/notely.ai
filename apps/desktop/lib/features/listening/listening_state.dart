// Listening session state machine.
//
// Coordinates the audio capture, transcript stream, and summarisation services behind one
// coherent state model so widgets never juggle scattered booleans, and so the future Rust IPC
// swap is localized to the injected services.
//
//   Idle ──start──▶ Listening ──pause──▶ Paused ──resume──▶ Listening
//                      │                                         │
//                      └──────────────── stop ───────────────────┘
//                                         ▼
//                                     Reviewing ──summarise/close──▶ Idle
//
// Pausing keeps the session + transcript alive (only capture is suspended). Stop moves to a
// Review state that retains the transcript until the user summarises or closes it.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/audio/meeting_audio_service.dart';
import '../../services/meeting/summary_service.dart';
import '../../services/transcript/transcript_service.dart';
import '../editor/editor_state.dart';

enum ListeningState { idle, listening, paused, reviewing }

/// Immutable-ish snapshot of the active meeting session.
class MeetingSession {
  MeetingSession({required this.activeFilePath});

  /// The editor file this session will summarise into (captured at start).
  final String? activeFilePath;
  final List<TranscriptEntry> segments = [];
}

class ListeningController extends ChangeNotifier {
  ListeningController({
    MeetingAudioService? audio,
    TranscriptService? transcript,
    SummaryService? summary,
  }) : _audio = audio ?? RecordMeetingAudioService(),
       _transcript = transcript ?? MockTranscriptService(),
       _summary = summary ?? const MockSummaryService();

  final MeetingAudioService _audio;
  final TranscriptService _transcript;
  final SummaryService _summary;

  StreamSubscription<TranscriptEvent>? _sub;

  ListeningState _state = ListeningState.idle;
  MeetingSession? _session;
  bool _summarising = false;
  String? _summariseError;
  String? _notice;

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

  List<TranscriptEntry> get entries =>
      List.unmodifiable(_session?.segments ?? const []);

  AudioCapabilities get audioCapabilities => _audio.capabilities;

  /// Begin a session tied to the currently open editor file.
  Future<void> start({String? activeFilePath}) async {
    if (_state != ListeningState.idle) return;
    _session = MeetingSession(activeFilePath: activeFilePath);
    _accumulated = Duration.zero;
    _runningSince = DateTime.now();
    _state = ListeningState.listening;
    notifyListeners();

    _sub = _transcript.events.listen(_onTranscriptEvent);
    await _audio.start();
    _transcript.start();
    // Reflect any permission result the audio probe produced.
    notifyListeners();
  }

  void _onTranscriptEvent(TranscriptEvent event) {
    switch (event) {
      case TranscriptSegmentEvent(:final segment):
        _session?.segments.add(segment);
        notifyListeners();
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
    notifyListeners();
    await _audio.pause();
    _transcript.pause();
  }

  Future<void> resume() async {
    if (_state != ListeningState.paused) return;
    _runningSince = DateTime.now();
    _state = ListeningState.listening;
    notifyListeners();
    await _audio.resume();
    _transcript.resume();
  }

  /// Stop capture and enter the Review state (transcript retained).
  Future<void> stop() async {
    if (_state == ListeningState.idle || _state == ListeningState.reviewing) {
      return;
    }
    _foldRunningSpan();
    _state = ListeningState.reviewing;
    notifyListeners();
    _transcript.stop();
    await _audio.stop();
    await _sub?.cancel();
    _sub = null;
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
        segments: _session!.segments,
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
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _transcript.dispose();
    _audio.dispose();
    super.dispose();
  }
}
