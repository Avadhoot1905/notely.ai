// Tests for InboxController: it lists captured meetings with their status from the engine, counts
// what still needs attention, retries via the engine (dedup-safe reprocess), and degrades to an
// empty list — not an error — when the engine is offline.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/inbox/inbox_state.dart';
import 'package:notely_desktop/ipc/engine_client.dart';
import 'package:notely_desktop/ipc/protocol.dart';

class _StubClient extends EngineClient {
  _StubClient({
    this.connected = true,
    this.meetings = const [],
    this.throwOnList = false,
  }) : super(host: '127.0.0.1', port: 1);

  final bool connected;
  final List<MeetingSummary> meetings;
  final bool throwOnList;
  final List<String> reprocessed = [];

  @override
  bool get isConnected => connected;

  @override
  Future<List<MeetingSummary>> listMeetings() async {
    if (throwOnList) throw const EngineError('boom');
    return meetings;
  }

  @override
  Future<String> reprocessMeeting(String meetingId) async {
    reprocessed.add(meetingId);
    return 'job-1';
  }
}

MeetingSummary _summary(String id, String title, ProcessingState? state) =>
    MeetingSummary(
      meeting: Meeting(
        id: id,
        title: title,
        createdAt: DateTime.utc(2026, 9, 13),
      ),
      status: state == null ? null : ProcessingStatus(state: state),
    );

void main() {
  group('InboxController', () {
    test(
      'refresh loads meetings and counts pending (non-ready) captures',
      () async {
        final client = _StubClient(
          meetings: [
            _summary('m1', 'Ready one', ProcessingState.ready),
            _summary('m2', 'Deferred one', ProcessingState.deferred),
            _summary('m3', 'Legacy (no status)', null), // treated as ready
          ],
        );
        final inbox = InboxController(engine: client);

        await inbox.refresh();

        expect(inbox.items.length, 3);
        expect(
          inbox.pendingCount,
          1,
          reason: 'only the deferred capture is pending',
        );
        expect(inbox.error, isNull);
      },
    );

    test('offline engine yields an empty inbox, not an error', () async {
      final inbox = InboxController(engine: _StubClient(connected: false));
      await inbox.refresh();
      expect(inbox.items, isEmpty);
      expect(inbox.error, isNull);
    });

    test('a list failure surfaces a calm error', () async {
      final inbox = InboxController(engine: _StubClient(throwOnList: true));
      await inbox.refresh();
      expect(inbox.error, isNotNull);
      expect(inbox.items, isEmpty);
    });

    test(
      'retry reprocesses the exact meeting (dedup-safe on the engine)',
      () async {
        final client = _StubClient();
        final inbox = InboxController(engine: client);
        await inbox.retry('m-42');
        expect(client.reprocessed, ['m-42']);
      },
    );

    test('toggle opens and closes the panel', () {
      final inbox = InboxController(engine: _StubClient(connected: false));
      expect(inbox.isOpen, isFalse);
      inbox.toggle();
      expect(inbox.isOpen, isTrue);
      inbox.toggle();
      expect(inbox.isOpen, isFalse);
    });
  });
}
