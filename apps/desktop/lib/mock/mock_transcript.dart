// Mock live-transcript feed.
//
// Stands in for the stream of transcription events the Rust engine will emit while a meeting
// is being recorded. [mockTranscriptScript] is replayed one entry at a time by the mock
// listening service, simulating speech arriving over time. Swapping this for the real engine
// event stream is a localized change in the listening controller.

/// A single attributed transcript line.
class TranscriptEntry {
  const TranscriptEntry({
    required this.time,
    required this.speaker,
    required this.text,
  });

  final String time;
  final String speaker;
  final String text;
}

/// The script replayed (in order, one every few seconds) while listening is active.
const List<TranscriptEntry> mockTranscriptScript = [
  TranscriptEntry(
    time: '10:42',
    speaker: 'Rahul',
    text: 'We should probably move the release to Friday.',
  ),
  TranscriptEntry(
    time: '10:43',
    speaker: 'Avadhoot',
    text: "That works for me. I'll update the deployment pipeline.",
  ),
  TranscriptEntry(
    time: '10:43',
    speaker: 'Priya',
    text: 'Can we make sure staging is tested before then?',
  ),
  TranscriptEntry(
    time: '10:44',
    speaker: 'Rahul',
    text: "Yes. I'll take care of the staging checklist.",
  ),
  TranscriptEntry(
    time: '10:45',
    speaker: 'Avadhoot',
    text: "I'll also document the rollback procedure.",
  ),
  TranscriptEntry(
    time: '10:46',
    speaker: 'Priya',
    text: 'Great. Let’s keep the whole thing reversible.',
  ),
];
