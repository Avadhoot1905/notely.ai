// Unit tests for the Dart side of the IPC protocol.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/protocol.dart';

void main() {
  test('protocol version matches the engine contract', () {
    // Must be bumped in lockstep with PROTOCOL_VERSION in engine/src/ipc/protocol.rs.
    expect(protocolVersion, 1);
  });

  test('requests serialize to the tagged wire shape', () {
    expect(const StartMeeting(title: 'Standup').toJson(), {
      'type': 'StartMeeting',
      'params': {'title': 'Standup'},
    });
    expect(const GetMom('m1').toJson(), {
      'type': 'GetMom',
      'params': {'meeting_id': 'm1'},
    });
  });
}
