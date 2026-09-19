// Companion controller/state tests.
//
// NOTE: this file imports NO audio types (MeetingAudioService/AudioFrame/VAD/ASR) — proving the
// companion is a pure projection of LiveMeetingState and never depends on the audio pipeline.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/meetings/companion_controller.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart'
    show AudioSource;
import 'package:notely_desktop/services/companion/companion_window_service.dart';
import 'package:notely_desktop/services/meeting/live_meeting_state.dart';
import 'package:notely_desktop/services/meeting/meeting_event_bus.dart';
import 'package:notely_desktop/services/meeting/meeting_events.dart';
import 'package:notely_desktop/services/meeting/transcript_segment.dart';
import 'package:notely_desktop/services/transcript/transcript_service.dart';

TranscriptSegment seg(
  String text, {
  int startSec = 0,
  String? speaker,
  TranscriptStatus status = TranscriptStatus.finalized,
}) => TranscriptSegment(
  id: text,
  start: Duration(seconds: startSec),
  end: Duration(seconds: startSec + 1),
  source: AudioSource.system,
  speaker: speaker,
  text: text,
  status: status,
);

/// Records what the controller pushes to the native window.
class _RecordingWindow implements CompanionWindowService {
  int shows = 0, hides = 0, updates = 0;
  CompanionSnapshot? last;
  final _c = StreamController<CompanionCommand>.broadcast();

  @override
  Stream<CompanionCommand> get commands => _c.stream;
  @override
  Future<void> show() async => shows++;
  @override
  Future<void> hide() async => hides++;
  @override
  Future<void> update(CompanionSnapshot s) async {
    updates++;
    last = s;
  }

  @override
  Future<void> dispose() async => _c.close();
}

void main() {
  group('CompanionController.project (pure)', () {
    test('maps status', () {
      String st(MeetingStatus s) => CompanionController.project(
        LiveMeetingState(status: s),
        elapsed: Duration.zero,
      ).status;
      expect(st(MeetingStatus.idle), 'idle');
      expect(st(MeetingStatus.live), 'listening');
      expect(st(MeetingStatus.paused), 'paused');
      expect(st(MeetingStatus.ended), 'stopped');
    });

    test('paused flag follows status; elapsed passes through', () {
      final snap = CompanionController.project(
        const LiveMeetingState(status: MeetingStatus.paused),
        elapsed: const Duration(seconds: 65),
      );
      expect(snap.paused, isTrue);
      expect(snap.elapsedSeconds, 65);
    });

    test('finalized segments become lines with speaker + mm:ss time', () {
      final snap = CompanionController.project(
        LiveMeetingState(
          status: MeetingStatus.live,
          transcript: [seg('hello', startSec: 3, speaker: 'Ada')],
        ),
        title: 'Standup',
        elapsed: const Duration(seconds: 3),
      );
      expect(snap.meetingTitle, 'Standup');
      expect(snap.lines, hasLength(1));
      expect(snap.lines.first, {
        'speaker': 'Ada',
        'time': '00:03',
        'text': 'hello',
      });
    });

    test('partial is projected separately (not duplicated into lines)', () {
      final snap = CompanionController.project(
        LiveMeetingState(
          status: MeetingStatus.live,
          transcript: [seg('final line')],
          partial: seg('draft', startSec: 5, status: TranscriptStatus.partial),
        ),
        elapsed: const Duration(seconds: 5),
      );
      expect(snap.lines.map((l) => l['text']), ['final line']);
      expect(snap.partial, isNotNull);
      expect(snap.partial!['text'], 'draft');
    });

    test('partial → final replaces cleanly with no duplication', () {
      final c = LiveMeetingStateController();
      c.apply(const MeetingStarted(Duration.zero));
      c.apply(
        TranscriptPartial(
          const Duration(seconds: 1),
          seg('draft', status: TranscriptStatus.partial),
        ),
      );
      var snap = CompanionController.project(c.state, elapsed: Duration.zero);
      expect(snap.lines, isEmpty);
      expect(snap.partial!['text'], 'draft');

      c.apply(
        TranscriptFinalized(const Duration(seconds: 1), seg('draft final')),
      );
      snap = CompanionController.project(c.state, elapsed: Duration.zero);
      expect(snap.lines.map((l) => l['text']), ['draft final']);
      expect(snap.partial, isNull);
    });

    test('only the tail is pushed for a long meeting', () {
      final many = [for (var i = 0; i < 45; i++) seg('line$i', startSec: i)];
      final snap = CompanionController.project(
        LiveMeetingState(status: MeetingStatus.live, transcript: many),
        elapsed: Duration.zero,
      );
      expect(snap.lines, hasLength(40));
      expect(snap.lines.first['text'], 'line5'); // dropped the oldest 5
    });
  });

  group('CompanionController presentation state', () {
    test(
      'show/hide drive the window and visibility, and push a snapshot',
      () async {
        final live = LiveMeetingStateController()
          ..apply(const MeetingStarted(Duration.zero));
        final win = _RecordingWindow();
        final c = CompanionController(
          window: win,
          source: live,
          liveState: () => live.state,
          elapsed: () => Duration.zero,
        );

        await c.show();
        expect(win.shows, 1);
        expect(win.updates, greaterThanOrEqualTo(1));
        expect(c.state.isVisible, isTrue);

        await c.hide();
        expect(win.hides, 1);
        expect(c.state.isVisible, isFalse);
        c.dispose();
      },
    );

    test('pushes reactively while visible, and NOT while hidden', () async {
      final live = LiveMeetingStateController()
        ..apply(const MeetingStarted(Duration.zero));
      final win = _RecordingWindow();
      final c = CompanionController(
        window: win,
        source: live,
        liveState: () => live.state,
        elapsed: () => Duration.zero,
      );
      await c.show();
      final before = win.updates;
      live.apply(TranscriptFinalized(Duration.zero, seg('a')));
      await Future<void>.delayed(Duration.zero);
      expect(win.updates, greaterThan(before));
      expect(win.last!.lines.map((l) => l['text']), contains('a'));

      await c.hide();
      final afterHide = win.updates;
      live.apply(TranscriptFinalized(Duration.zero, seg('b')));
      await Future<void>.delayed(Duration.zero);
      expect(win.updates, afterHide, reason: 'no pushes while hidden');
      c.dispose();
    });

    test(
      'setPosition / setExpanded change companion state, never meeting state',
      () {
        final live = LiveMeetingStateController()
          ..apply(const MeetingStarted(Duration.zero))
          ..apply(TranscriptFinalized(Duration.zero, seg('x')));
        final win = _RecordingWindow();
        final c = CompanionController(
          window: win,
          source: live,
          liveState: () => live.state,
          elapsed: () => Duration.zero,
        );
        final meetingBefore = live.state;

        c.setPosition(const Offset(12, 34));
        c.setExpanded(true);

        expect(c.state.position, const Offset(12, 34));
        expect(c.state.expansion, CompanionExpansion.expanded);
        // Meeting state is untouched by companion presentation changes.
        expect(identical(live.state, meetingBefore), isTrue);
        expect(live.state.transcript.map((s) => s.text), ['x']);
        c.dispose();
      },
    );
  });

  test(
    'integration: mock transcript → bus → LiveMeetingState → companion',
    () async {
      final bus = MeetingEventBus();
      final live = LiveMeetingStateController();
      bus.events.listen(live.apply);
      final win = _RecordingWindow();
      final c = CompanionController(
        window: win,
        source: live,
        liveState: () => live.state,
        elapsed: () => Duration.zero,
        title: () => 'Standup',
      );
      await c.show();

      final mock = MockTranscriptService(
        interval: const Duration(milliseconds: 10),
      );
      bus.emit(const MeetingStarted(Duration.zero));
      final sub = mock.events.listen((e) {
        if (e is TranscriptSegmentEvent) {
          bus.emit(
            TranscriptFinalized(
              Duration.zero,
              seg(e.segment.text, speaker: e.segment.speaker),
            ),
          );
        }
      });
      mock.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(win.last, isNotNull);
      expect(
        win.last!.lines,
        isNotEmpty,
        reason: 'mock transcript reached the companion',
      );
      expect(win.last!.meetingTitle, 'Standup');

      await sub.cancel();
      await mock.dispose();
      await bus.dispose();
      c.dispose();
    },
  );
}
