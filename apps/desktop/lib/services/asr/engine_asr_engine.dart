// Engine-backed ASR (Phase 1, batch).
//
// The real integration point for transcription: the captured meeting recording (a local WAV) is
// submitted to the Rust engine over IPC via the existing `ProcessMeeting { Audio { path } }` path,
// which runs media (FFmpeg → mono 16 kHz) → Qwen3-ASR → persists the transcript BEFORE any AI. We
// wait for `TranscriptionCompleted` (the transcript is saved by then, independent of the later AI
// tail) and fetch it with `GetTranscript`. The chain:
//
//   recording.wav → ProcessMeeting(Audio) → [media → Qwen3-ASR → save_transcript] → GetTranscript
//
// The engine owns all ASR/media logic; nothing here re-implements it. This keeps the Qwen/IPC
// details behind the [AsrEngine] seam so `ListeningController` stays backend-neutral.

import 'dart:async';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart' as ipc;
import '../audio/audio_frame.dart' show AudioSource;
import '../meeting/transcript_segment.dart';
import 'asr_engine.dart';

class EngineAsrEngine implements AsrEngine {
  EngineAsrEngine({
    required this.client,
    this.title,
    this.timeout = const Duration(minutes: 5),
  });

  final EngineClient client;

  /// Optional meeting title passed to the engine.
  final String? title;

  /// How long to wait for transcription to finish before giving up (deferred, not lost).
  final Duration timeout;

  @override
  Future<List<TranscriptSegment>> transcribe(AudioRecording recording) async {
    // Local-first: with no backend there is no on-device ASR fallback — be honest, don't fake it.
    if (!client.isConnected) {
      throw const AsrUnavailableException('engine not connected');
    }

    final meetingId = await _runToTranscription(recording);
    final transcript = await client.getTranscript(meetingId);
    return mapTranscript(transcript, recording.source);
  }

  @override
  Future<List<TranscriptSegment>> transcribeChunk(AudioChunk chunk) async {
    if (!client.isConnected) {
      throw const AsrUnavailableException('engine not connected');
    }
    // Synchronous, no job/persistence. Chunk-relative times are shifted onto the meeting timeline.
    final transcript = await client.transcribeChunk(chunk.path);
    return mapTranscript(transcript, chunk.source, offset: chunk.offset);
  }

  /// Submit the audio and resolve the meeting id once its transcript has been produced+persisted.
  ///
  /// Resolves on `TranscriptionCompleted` (transcript saved; the AI tail may still be running), so a
  /// transcript appears even when the later enrichment defers (e.g. the LLM is down). A failure
  /// before that point (e.g. the ASR runtime is unreachable) surfaces as [AsrUnavailableException].
  Future<String> _runToTranscription(AudioRecording recording) async {
    final done = Completer<String>();
    String? meetingId;

    // Subscribe BEFORE submitting so no early event is missed.
    final sub = client.events().listen((event) {
      if (done.isCompleted) return;
      switch (event.type) {
        case ipc.EngineEventType.processingStarted:
          meetingId = event.meetingId ?? meetingId;
        case ipc.EngineEventType.transcriptionCompleted:
        case ipc.EngineEventType.jobCompleted:
          final id = event.meetingId ?? meetingId;
          if (id != null) done.complete(id);
        case ipc.EngineEventType.jobFailed:
          // Transcription didn't reach completion (commonly: ASR runtime unreachable).
          done.completeError(
            AsrUnavailableException(event.message ?? 'transcription failed'),
          );
        default:
          break;
      }
    });

    try {
      final jobId = await client.processMeeting(
        ipc.AudioInput(title: title, path: recording.path),
      );
      return await done.future.timeout(
        timeout,
        onTimeout: () => throw AsrUnavailableException(
          'engine did not transcribe job $jobId in time',
        ),
      );
    } finally {
      await sub.cancel();
    }
  }
}

/// Map the engine's [ipc.Transcript] to domain [TranscriptSegment]s tagged with the capture [source].
/// Pure and side-effect free so it is unit-testable without a live engine. Segment times are seconds
/// from the audio start plus [offset] (for a live chunk, its position on the meeting timeline; for a
/// full recording, [Duration.zero]); empty-text segments are dropped.
List<TranscriptSegment> mapTranscript(
  ipc.Transcript transcript,
  AudioSource source, {
  Duration offset = Duration.zero,
}) {
  final out = <TranscriptSegment>[];
  var i = 0;
  for (final s in transcript.segments) {
    if (s.text.trim().isEmpty) continue;
    out.add(
      TranscriptSegment(
        id: '${source.name}-${offset.inMilliseconds}-${i++}',
        start: offset + _seconds(s.start),
        end: offset + _seconds(s.end),
        source: source,
        speaker: s.speakerId,
        text: s.text,
        confidence: s.confidence,
      ),
    );
  }
  return out;
}

Duration _seconds(double s) =>
    Duration(microseconds: (s * Duration.microsecondsPerSecond).round());
