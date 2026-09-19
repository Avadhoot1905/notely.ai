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
import '../../services/audio/vad.dart';
import '../../services/audio/wav_recorder.dart';
import '../../services/asr/asr_engine.dart';
import '../../services/meeting/live_meeting_state.dart';
import '../../services/meeting/meeting_event_bus.dart';
import '../../services/meeting/meeting_events.dart';
import '../../services/meeting/transcript_segment.dart';
import '../../services/meeting/summary_service.dart';
import '../../services/transcript/transcript_service.dart';
import '../editor/editor_state.dart';

/// TEMPORARY capture-diagnostics switch: on in debug builds only, so release capture pays nothing.
const bool _kCaptureDiag = kDebugMode;

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
    AsrEngine? asr,
    // Default to a silent transcript: the running app shows no canned lines. Real transcript comes
    // from ASR (the injected [AsrEngine] seam, batch at stop()); tests inject MockTranscriptService
    // for scripted content, or a fake AsrEngine to exercise the capture→transcript path.
  }) : _transcript = transcript ?? SilentTranscriptService(),
       _summary = summary ?? const MockSummaryService(),
       // ignore: prefer_initializing_formals — public param is `asr`, field is private `_asr`.
       _asr = asr {
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

  /// Real ASR seam (batch, at stop()). Null → capture runs but no transcription (tests / offline
  /// composition). Keeps Qwen/IPC details out of this controller.
  final AsrEngine? _asr;

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

  // --- microphone recording → batch ASR (per session) ---
  WavRecorder? _recorder;
  bool _recorderStarting = false;
  DateTime? _sessionStartedAt;
  bool _transcribing = false;
  int _liveChunkSeq = 0;

  /// True while the engine is transcribing the captured recording (review shows a progress state).
  bool get isTranscribing => _transcribing;

  /// Speech segments produced this session (ready for the ASR seam). Diagnostic.
  int get speechSegmentCount => _speechSegmentCount;

  // --- capture observability (debug-only; TEMPORARY diagnostic scaffolding) ---
  // Aggregated, boundary-level metadata (never raw audio) so a live "hello" test can prove whether
  // mic PCM reaches the VAD and crosses the speech threshold. Timer-free: flushed on frame arrival
  // at most once per second, so it self-limits and leaks nothing when capture stops.
  final Map<AudioSource, _SourceDiag> _diagStats = {};
  DateTime? _lastDiagAt;

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
    _sessionStartedAt = _runningSince;
    _state = ListeningState.listening;
    _speechSegmentCount = 0;
    _bus.emit(MeetingStarted(Duration.zero)); // resets Live Meeting State
    notifyListeners();

    // Wire capture → ingestion → VAD → segmentation (per source). Runs for real; segments are
    // ready for the ASR seam. Does not touch the transcript path.
    _ingestion = AudioIngestion(startedAt: DateTime.now());
    _diagStats.clear();
    _lastDiagAt = null;
    _segmenters
      ..clear()
      ..[AudioSource.microphone] = SpeechSegmenter(
        source: AudioSource.microphone,
        vad: _diagVad(AudioSource.microphone),
      )
      ..[AudioSource.system] = SpeechSegmenter(
        source: AudioSource.system,
        vad: _diagVad(AudioSource.system),
      );
    _recorder = null;
    _recorderStarting = false;
    _framesSub = _audio.frames.listen((f) {
      _ingestion?.add(f);
      // Record the microphone (the local participant) to a WAV for batch ASR at stop(). System audio
      // is a separate source and is intentionally NOT mixed in here (Phase 1). Only when ASR is wired.
      if (_asr != null && f.source == AudioSource.microphone) {
        _recordMicFrame(f);
      }
    });
    _ingestSub = _ingestion!.frames.listen((f) {
      final seg = _segmenters[f.source]?.add(f);
      if (seg != null) {
        _speechSegmentCount++;
        if (_kCaptureDiag) _diagStats[f.source]?.segments++;
        // Live preview: transcribe each closed mic segment for an immediate companion transcript.
        // Best-effort and ephemeral — the authoritative transcript is the full-audio pass at stop().
        if (_asr != null && seg.source == AudioSource.microphone) {
          unawaited(_transcribeLiveSegment(seg));
        }
      }
      if (_kCaptureDiag) _maybeLogCaptureDiag();
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
    final recording = await _finishRecording();
    await _teardownCapturePipeline();
    await _sub?.cancel();
    _sub = null;
    // Kick off batch transcription of the captured recording (non-blocking): segments arrive as
    // TranscriptFinalized events and populate the review transcript when the engine returns them.
    if (recording != null) {
      unawaited(_transcribeRecording(recording));
    }
  }

  // --- microphone recording + batch ASR ---------------------------------------------------------

  /// Feed one mic frame to the WAV recorder, creating it lazily on the first frame (whose format
  /// sets the WAV header). Frames arriving during the async open are dropped (a few ms of audio).
  void _recordMicFrame(AudioFrame f) {
    final rec = _recorder;
    if (rec != null) {
      rec.add(f.data);
      return;
    }
    if (_recorderStarting) return;
    _recorderStarting = true;
    unawaited(
      WavRecorder.createTemp(
        source: AudioSource.microphone,
        sampleRate: f.sampleRate,
        channels: f.channels,
      ).then((r) {
        // If the session already ended before the file opened, don't leak it.
        if (_disposed || _state != ListeningState.listening) {
          unawaited(r.discard());
        } else {
          _recorder = r;
        }
      }),
    );
  }

  /// Finalize the recording (if any) and return it as an [AudioRecording], or null if nothing was
  /// captured. Clears recorder state either way.
  Future<AudioRecording?> _finishRecording() async {
    final rec = _recorder;
    _recorder = null;
    _recorderStarting = false;
    if (rec == null) return null;
    final path = await rec.finish();
    if (rec.dataBytes == 0) {
      unawaited(rec.discard());
      return null;
    }
    return AudioRecording(
      path: path,
      source: AudioSource.microphone,
      startedAt: _sessionStartedAt ?? DateTime.now(),
    );
  }

  /// Live preview: transcribe one closed mic segment and append it to the transcript as it arrives.
  /// Best-effort — failures are swallowed (the authoritative full-audio pass at stop() covers them).
  Future<void> _transcribeLiveSegment(SpeechSegment seg) async {
    final asr = _asr;
    if (asr == null || _disposed || seg.frames.isEmpty) return;
    String? path;
    try {
      final fmt = seg.frames.first;
      path = await WavRecorder.writeTemp(
        source: seg.source,
        sampleRate: fmt.sampleRate,
        channels: fmt.channels,
        pcm: seg.pcm(),
        nonce: DateTime.now().microsecondsSinceEpoch + (_liveChunkSeq++),
      );
      final segments = await asr.transcribeChunk(
        AudioChunk(path: path, source: seg.source, offset: seg.start),
      );
      if (_disposed || _bus.isClosed) return;
      for (final s in segments) {
        _bus.emit(TranscriptFinalized(s.start, s));
      }
    } catch (e) {
      debugPrint(
        'live chunk ASR skipped: $e',
      ); // best-effort; batch pass is authoritative
    } finally {
      if (path != null) unawaited(WavRecorder.deleteQuietly(path));
    }
  }

  /// Transcribe the recording via the engine ASR seam and fold the result into the meeting stream.
  /// Failures are surfaced as a calm notice — never a crash, never a faked transcript.
  Future<void> _transcribeRecording(AudioRecording recording) async {
    final asr = _asr;
    if (asr == null || _disposed) return;
    _transcribing = true;
    notifyListeners();
    try {
      final segments = await asr.transcribe(recording);
      if (_disposed || _bus.isClosed) return;
      if (segments.isNotEmpty) {
        // Authoritative: replace any ephemeral live previews with the full-audio transcript.
        _bus.emit(TranscriptReplaced(elapsed, segments));
      } else {
        _notice = 'No speech was transcribed for this session.';
      }
    } on AsrUnavailableException catch (e) {
      _notice =
          'Transcription unavailable — the engine or ASR runtime isn’t running.';
      debugPrint('ASR unavailable: ${e.reason}');
    } catch (e) {
      _notice = 'Transcription didn’t finish; your recording is saved.';
      debugPrint('ASR error: $e');
    } finally {
      _transcribing = false;
      if (!_disposed) notifyListeners();
    }
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

  /// The VAD each segmenter uses. In debug, wraps the real [EnergyVad] so per-frame energy/verdict
  /// is aggregated for the [_maybeLogCaptureDiag] boundary report without altering VAD behaviour.
  VoiceActivityDetector _diagVad(AudioSource source) {
    final base = EnergyVad();
    if (!_kCaptureDiag) return base;
    final stats = _diagStats[source] = _SourceDiag();
    return _DiagnosticVad(base, stats);
  }

  /// Emit an aggregated capture-boundary line at most once per second (metadata only, no audio).
  /// This is where a live "hello" shows up: mic rms/peak and speech-frame ratio jump above baseline.
  void _maybeLogCaptureDiag() {
    final now = DateTime.now();
    final last = _lastDiagAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastDiagAt = now;
    final dropped = _ingestion?.dropped ?? 0;
    for (final src in AudioSource.values) {
      final d = _diagStats[src];
      if (d == null || d.frames == 0) {
        debugPrint('[capture-diag] ${src.name}: no frames this window');
        continue;
      }
      final rmsAvg = (d.rmsSum / d.frames).toStringAsFixed(4);
      final speechRatio = (d.speechFrames / d.frames).toStringAsFixed(2);
      debugPrint(
        '[capture-diag] ${src.name}: frames=${d.frames} bytes=${d.bytes} '
        'dropped=$dropped | rms(min/max/avg)=${d.rmsMin.toStringAsFixed(4)}/'
        '${d.rmsMax.toStringAsFixed(4)}/$rmsAvg '
        'peak(min/max/avg)=${d.peakMin}/${d.peakMax}/${d.peakSum ~/ d.frames} '
        'speech=${d.speechFrames}/${d.frames} (ratio=$speechRatio) '
        'segments(total)=${d.segments}',
      );
      d.resetWindow();
    }
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
    unawaited(_recorder?.discard());
    _recorder = null;
    unawaited(_ingestion?.dispose());
    _transcript.dispose();
    _audio.dispose();
    _live.removeListener(notifyListeners);
    _live.dispose();
    unawaited(_bus.dispose());
    super.dispose();
  }
}

// --- TEMPORARY capture-diagnostics scaffolding (debug builds only) ---------------------------------
// Aggregates boundary metadata for the [_maybeLogCaptureDiag] report. Windowed counters reset each
// log; `segments` is cumulative for the session. No raw audio is retained or logged.
class _SourceDiag {
  int frames = 0;
  int bytes = 0;
  int speechFrames = 0;
  double rmsMin = 1.0;
  double rmsMax = 0.0;
  double rmsSum = 0.0;
  int peakMin = 32768;
  int peakMax = 0;
  int peakSum = 0;
  int segments = 0; // cumulative across the session

  void resetWindow() {
    frames = 0;
    bytes = 0;
    speechFrames = 0;
    rmsMin = 1.0;
    rmsMax = 0.0;
    rmsSum = 0.0;
    peakMin = 32768;
    peakMax = 0;
    peakSum = 0;
  }
}

/// Pass-through VAD that records each frame's energy/verdict/peak into a [_SourceDiag] before
/// returning the real verdict unchanged — so diagnostics use the SAME numbers the segmenter acts on.
class _DiagnosticVad implements VoiceActivityDetector {
  _DiagnosticVad(this._inner, this._stats);

  final VoiceActivityDetector _inner;
  final _SourceDiag _stats;

  @override
  VadResult analyze(AudioFrame frame) {
    final r = _inner.analyze(frame);
    final s = _stats;
    s.frames++;
    s.bytes += frame.data.lengthInBytes;
    s.rmsSum += r.energy;
    if (r.energy < s.rmsMin) s.rmsMin = r.energy;
    if (r.energy > s.rmsMax) s.rmsMax = r.energy;
    if (r.isSpeech) s.speechFrames++;
    var peak = 0;
    for (final v in frame.samples) {
      final a = v < 0 ? -v : v;
      if (a > peak) peak = a;
    }
    if (peak < s.peakMin) s.peakMin = peak;
    if (peak > s.peakMax) s.peakMax = peak;
    s.peakSum += peak;
    return r;
  }
}
