// Engine-backed meeting summarisation.
//
// This is the real integration point: the transcript captured during a session is sent to the
// Rust engine over IPC, which runs the deterministic-prep + two-pass AI pipeline and renders a
// Minutes-of-Meeting (MOM) Markdown document. The full chain is:
//
//   segments → ProcessMeeting(transcript) → [engine pipeline + events] → JobCompleted
//            → GetMom(meetingId) → Markdown → editor
//
// The engine owns all summarisation logic; nothing here re-implements it. When the engine is not
// connected (local-first: the app must stay usable offline), we defer to a deterministic offline
// [fallback]. A *connected* engine's failure is never swallowed — it propagates so the UI can
// surface it, per the project's "don't paper over failures" rule.

import 'dart:async';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart' as ipc;
import '../transcript/transcript_service.dart';
import 'summary_service.dart';

class EngineSummaryService implements SummaryService {
  EngineSummaryService({
    required this.client,
    this.fallback = const MockSummaryService(),
    this.timeout = const Duration(minutes: 5),
  });

  final EngineClient client;
  final SummaryService fallback;
  final Duration timeout;

  @override
  Future<String> summarise({
    required List<TranscriptEntry> segments,
    required String currentMarkdown,
    String? title,
  }) async {
    // No backend available → deterministic offline summary (local-first degradation).
    if (!client.isConnected) {
      return fallback.summarise(
        segments: segments,
        currentMarkdown: currentMarkdown,
        title: title,
      );
    }

    final transcript = _toTranscript(segments);
    final meetingId = await _runPipeline(title, transcript);
    final mom = await client.getMom(meetingId);
    return _compose(currentMarkdown, mom);
  }

  /// Submit the transcript, then await the job's terminal event, and return the meeting id.
  ///
  /// The engine persists the transcript (the source of truth) BEFORE any AI runs, so a job failure
  /// or timeout means the capture is safe but enrichment is deferred — surfaced as a
  /// [DeferredProcessingException] carrying the persisted meeting id (for a later, dedup-safe
  /// retry), never as data loss.
  Future<String> _runPipeline(String? title, ipc.Transcript transcript) async {
    final done = Completer<String>();
    // Captured as soon as the engine persists the meeting; available even if enrichment then fails.
    String? meetingId;

    // Subscribe BEFORE submitting so we can't miss an event.
    final sub = client.events().listen((event) {
      if (done.isCompleted) return;
      switch (event.type) {
        case ipc.EngineEventType.processingStarted:
          meetingId = event.meetingId ?? meetingId;
        case ipc.EngineEventType.jobCompleted:
          final id = event.meetingId ?? meetingId;
          if (id != null) done.complete(id);
        case ipc.EngineEventType.jobFailed:
          done.completeError(
            DeferredProcessingException(
              meetingId: meetingId,
              reason: event.message ?? 'processing failed',
            ),
          );
        default:
          break;
      }
    });

    try {
      final jobId = await client.processMeeting(
        ipc.TranscriptInput(title: title, transcript: transcript),
      );
      return await done.future.timeout(
        timeout,
        onTimeout: () => throw DeferredProcessingException(
          meetingId: meetingId,
          reason: 'engine did not finish job $jobId in time',
        ),
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Map the UI transcript entries to the engine's [ipc.Transcript]. Timestamps in the UI are
  /// display strings ("10:42"); we assign monotonic ordering so segments stay ordered and valid.
  ipc.Transcript _toTranscript(List<TranscriptEntry> segments) {
    final out = <ipc.TranscriptSegment>[];
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      out.add(
        ipc.TranscriptSegment(
          speakerId: s.speaker,
          start: i.toDouble(),
          end: (i + 1).toDouble(),
          text: s.text,
        ),
      );
    }
    return ipc.Transcript(segments: out);
  }

  /// Preserve the user's existing note, appending the engine-rendered MOM beneath it.
  String _compose(String currentMarkdown, String mom) {
    final existing = currentMarkdown.trimRight();
    if (existing.isEmpty) return mom;
    return '$existing\n\n$mom';
  }
}
