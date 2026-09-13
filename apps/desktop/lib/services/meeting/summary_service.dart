// Meeting summarisation abstraction.
//
// Turns a transcript (+ the note's current Markdown) into Markdown to write back into the
// user's open note. The UI/controller calls this; the summary logic never lives in widgets.
//
// Future: MockSummaryService → IPC → Rust meeting engine (Meeting IR → Markdown). The method
// surface is designed so that swap is invisible to callers.

import '../transcript/transcript_service.dart';

/// Raised when the source was safely captured/persisted but AI enrichment could not finish (e.g.
/// the local model was unavailable, or it timed out). This is deliberately NOT a data-loss error:
/// the capture is safe and enrichment can be retried later. [meetingId] identifies the persisted
/// capture when the engine accepted it, so the retry can target the exact meeting (no duplicate).
class DeferredProcessingException implements Exception {
  const DeferredProcessingException({this.meetingId, this.reason});

  /// The engine's id for the safely-persisted capture, if enrichment reached the engine.
  final String? meetingId;

  /// A short reason (e.g. "model unavailable"), for logging — not shown verbatim to the user.
  final String? reason;

  @override
  String toString() =>
      'DeferredProcessingException(meetingId: $meetingId, reason: $reason)';
}

abstract class SummaryService {
  /// Produce Markdown for the meeting. [currentMarkdown] is the note's existing content (so an
  /// implementation can preserve or append); [title] hints at a heading.
  Future<String> summarise({
    required List<TranscriptEntry> segments,
    required String currentMarkdown,
    String? title,
  });
}

/// Deterministic, offline summary generator. Groups the transcript by speaker, extracts simple
/// action-item candidates, and appends a structured "Meeting Summary" section to the existing
/// note — never discarding what the user already wrote.
class MockSummaryService implements SummaryService {
  const MockSummaryService();

  @override
  Future<String> summarise({
    required List<TranscriptEntry> segments,
    required String currentMarkdown,
    String? title,
  }) async {
    final buffer = StringBuffer();
    final existing = currentMarkdown.trimRight();
    if (existing.isNotEmpty) {
      buffer.writeln(existing);
      buffer.writeln();
    }

    buffer.writeln('## Meeting Summary');
    buffer.writeln();

    if (segments.isEmpty) {
      buffer.writeln('_No transcript was captured for this session._');
      return buffer.toString();
    }

    final speakers = <String>{for (final s in segments) s.speaker};
    final first = segments.first.time;
    final last = segments.last.time;

    buffer.writeln('**Participants:** ${speakers.join(', ')}  ');
    buffer.writeln('**Span:** $first – $last  ');
    buffer.writeln('**Segments:** ${segments.length}');
    buffer.writeln();

    buffer.writeln('### Discussion');
    buffer.writeln();
    for (final s in segments) {
      buffer.writeln('- **${s.speaker}** (${s.time}): ${s.text}');
    }
    buffer.writeln();

    // Naive action-item extraction: lines implying a commitment.
    final actions = segments.where((s) {
      final t = s.text.toLowerCase();
      return t.contains("i'll") ||
          t.contains('i will') ||
          t.contains('take care') ||
          t.contains('make sure') ||
          t.contains('update') ||
          t.contains('document');
    }).toList();

    buffer.writeln('### Action Items');
    buffer.writeln();
    if (actions.isEmpty) {
      buffer.writeln('- [ ] _No explicit action items detected._');
    } else {
      for (final a in actions) {
        buffer.writeln('- [ ] ${a.text} — ${a.speaker}');
      }
    }

    return buffer.toString();
  }
}
