import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/meeting/live_meeting_state.dart';
import 'package:notely_desktop/services/meeting/meeting_event_bus.dart';
import 'package:notely_desktop/services/meeting/meeting_events.dart';
import 'package:notely_desktop/services/meeting/transcript_segment.dart';
import 'package:notely_desktop/services/transcript/transcript_service.dart';

TranscriptSegment seg(String text) => TranscriptSegment(
  id: text,
  start: Duration.zero,
  end: const Duration(seconds: 1),
  source: AudioSource.system,
  text: text,
);

void main() {
  group('MeetingEventBus', () {
    test('fans out to multiple independent consumers', () async {
      final bus = MeetingEventBus();
      final a = <MeetingEvent>[];
      final b = <MeetingEvent>[];
      bus.events.listen(a.add);
      bus.events.listen(b.add);

      bus.emit(const MeetingStarted(Duration.zero));
      bus.emit(TranscriptFinalized(Duration.zero, seg('hi')));
      await Future<void>.delayed(Duration.zero);

      expect(a, hasLength(2));
      expect(b, hasLength(2));
      await bus.dispose();
    });
  });

  group('LiveMeetingStateController', () {
    test('MeetingStarted makes the meeting live and resets transcript', () {
      final c = LiveMeetingStateController();
      c.apply(TranscriptFinalized(Duration.zero, seg('stale')));
      c.apply(const MeetingStarted(Duration.zero));
      expect(c.state.status, MeetingStatus.live);
      expect(c.state.transcript, isEmpty);
    });

    test('TranscriptFinalized appends and clears any partial', () {
      final c = LiveMeetingStateController();
      c.apply(const MeetingStarted(Duration.zero));
      c.apply(TranscriptPartial(const Duration(seconds: 1), seg('typing…')));
      expect(c.state.partial, isNotNull);
      c.apply(TranscriptFinalized(const Duration(seconds: 1), seg('done')));
      expect(c.state.partial, isNull);
      expect(c.state.transcript.map((s) => s.text), ['done']);
    });

    test('lifecycle transitions update status', () {
      final c = LiveMeetingStateController();
      c.apply(const MeetingStarted(Duration.zero));
      c.apply(const MeetingPaused(Duration(seconds: 2)));
      expect(c.state.status, MeetingStatus.paused);
      c.apply(const MeetingResumed(Duration(seconds: 3)));
      expect(c.state.status, MeetingStatus.live);
      c.apply(const MeetingStopped(Duration(seconds: 4)));
      expect(c.state.status, MeetingStatus.ended);
      expect(c.state.elapsed, const Duration(seconds: 4));
    });

    test('reset returns to idle/empty', () {
      final c = LiveMeetingStateController();
      c.apply(const MeetingStarted(Duration.zero));
      c.apply(TranscriptFinalized(Duration.zero, seg('x')));
      c.reset();
      expect(c.state.status, MeetingStatus.idle);
      expect(c.state.transcript, isEmpty);
    });

    test('notifies listeners on each applied event', () {
      final c = LiveMeetingStateController();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.apply(const MeetingStarted(Duration.zero));
      c.apply(TranscriptFinalized(Duration.zero, seg('a')));
      expect(notifications, 2);
    });
  });

  test('mock transcript → events → live state (end to end, no audio)', () async {
    // Mirrors the ListeningController wiring: a transcript source feeds the bus, which the live
    // state projects. Proves the mock path reaches Live Meeting State through the event boundary.
    final bus = MeetingEventBus();
    final live = LiveMeetingStateController();
    bus.events.listen(live.apply);

    final mock = MockTranscriptService(
      interval: const Duration(milliseconds: 10),
    );
    bus.emit(const MeetingStarted(Duration.zero));
    final sub = mock.events.listen((e) {
      if (e is TranscriptSegmentEvent) {
        bus.emit(
          TranscriptFinalized(
            Duration.zero,
            TranscriptSegment(
              id: 's${live.state.transcript.length}',
              start: Duration.zero,
              end: Duration.zero,
              source: AudioSource.system,
              speaker: e.segment.speaker,
              text: e.segment.text,
            ),
          ),
        );
      }
    });

    mock.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(live.state.transcript, isNotEmpty);
    expect(live.state.transcript.first.text, isNotEmpty);

    await sub.cancel();
    await mock.dispose();
    await bus.dispose();
  });
}
