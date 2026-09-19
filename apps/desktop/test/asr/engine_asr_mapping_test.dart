import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/protocol.dart' as ipc;
import 'package:notely_desktop/services/asr/engine_asr_engine.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/meeting/transcript_segment.dart';

void main() {
  test('mapTranscript converts engine segments to domain segments', () {
    final t = ipc.Transcript(
      segments: const [
        ipc.TranscriptSegment(
          speakerId: 'S1',
          start: 0.0,
          end: 1.5,
          text: 'hello there',
          confidence: 0.9,
        ),
        ipc.TranscriptSegment(start: 1.5, end: 2.0, text: '   '), // dropped
        ipc.TranscriptSegment(start: 2.0, end: 3.25, text: 'second line'),
      ],
    );

    final out = mapTranscript(t, AudioSource.microphone);

    expect(out.length, 2, reason: 'empty-text segment is dropped');
    expect(out[0].id, 'microphone-0-0');
    expect(out[0].text, 'hello there');
    expect(out[0].speaker, 'S1');
    expect(out[0].confidence, 0.9);
    expect(out[0].source, AudioSource.microphone);
    expect(out[0].start, Duration.zero);
    expect(out[0].end, const Duration(milliseconds: 1500));
    expect(out[0].status, TranscriptStatus.finalized);

    // Ids are contiguous across kept segments (dropped one does not consume an index).
    expect(out[1].id, 'microphone-0-1');
    expect(out[1].start, const Duration(seconds: 2));
    expect(out[1].end, const Duration(milliseconds: 3250));
    expect(out[1].speaker, isNull);
    expect(out[1].confidence, isNull);
  });

  test('mapTranscript applies a timeline offset (live chunk placement)', () {
    final t = ipc.Transcript(
      segments: const [
        ipc.TranscriptSegment(start: 0.0, end: 0.5, text: 'live'),
      ],
    );
    final out = mapTranscript(
      t,
      AudioSource.microphone,
      offset: const Duration(seconds: 12),
    );
    expect(out.single.start, const Duration(seconds: 12));
    expect(out.single.end, const Duration(milliseconds: 12500));
    expect(out.single.id, 'microphone-12000-0');
  });

  test('mapTranscript on an empty transcript yields nothing', () {
    expect(mapTranscript(const ipc.Transcript(), AudioSource.system), isEmpty);
  });
}
