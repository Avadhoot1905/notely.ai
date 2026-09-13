// Unit tests for the Dart side of the IPC protocol: request serialization, response decoding,
// and event decoding. These pin the wire shape against engine/src/ipc/protocol.rs + events.rs.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/protocol.dart';

void main() {
  test('protocol version matches the engine contract', () {
    // Must be bumped in lockstep with PROTOCOL_VERSION in engine/src/ipc/protocol.rs.
    expect(protocolVersion, 1);
  });

  group('requests serialize to the tagged wire shape', () {
    test('Health is a bare tag with no params', () {
      expect(const Health().toJson(), {'type': 'Health'});
    });

    test('GetMom carries meeting_id', () {
      expect(const GetMom('m1').toJson(), {
        'type': 'GetMom',
        'params': {'meeting_id': 'm1'},
      });
    });

    test('GetJob / CancelJob carry job_id', () {
      expect(const GetJob('j1').toJson(), {
        'type': 'GetJob',
        'params': {'job_id': 'j1'},
      });
      expect(const CancelJob('j1').toJson(), {
        'type': 'CancelJob',
        'params': {'job_id': 'j1'},
      });
    });

    test('ProcessMeeting wraps a tagged ProcessInput', () {
      final req = ProcessMeeting(
        TranscriptInput(
          title: 'Standup',
          transcript: const Transcript(
            segments: [
              TranscriptSegment(
                speakerId: 'Rahul',
                start: 0,
                end: 1,
                text: 'Ship on Friday.',
              ),
            ],
          ),
        ),
      );
      expect(req.toJson(), {
        'type': 'ProcessMeeting',
        'params': {
          'input': {
            'kind': 'transcript',
            'title': 'Standup',
            'transcript': {
              'segments': [
                {
                  'speaker_id': 'Rahul',
                  'start': 0.0,
                  'end': 1.0,
                  'text': 'Ship on Friday.',
                },
              ],
            },
          },
        },
      });
    });

    test('AudioInput serializes with kind=audio', () {
      expect(const ProcessMeeting(AudioInput(path: '/tmp/a.wav')).toJson(), {
        'type': 'ProcessMeeting',
        'params': {
          'input': {'kind': 'audio', 'title': null, 'path': '/tmp/a.wav'},
        },
      });
    });
  });

  group('responses decode from the {type, data} shape', () {
    test('Health', () {
      final r = Response.fromJson({
        'type': 'Health',
        'data': {
          'protocol_version': 1,
          'engine_ok': true,
          'llm_ok': false,
          'model': 'qwen3:1.7b',
          'asr_provider': 'qwen3asr',
        },
      });
      expect(r, isA<HealthResponse>());
      final info = (r as HealthResponse).info;
      expect(info.model, 'qwen3:1.7b');
      expect(info.llmOk, false);
    });

    test('JobAccepted', () {
      final r = Response.fromJson({
        'type': 'JobAccepted',
        'data': {'job_id': 'j-42'},
      });
      expect((r as JobAcceptedResponse).jobId, 'j-42');
    });

    test('Meeting', () {
      final r = Response.fromJson({
        'type': 'Meeting',
        'data': {
          'id': 'm1',
          'title': 'Release planning',
          'created_at': '2026-09-13T10:42:00Z',
          'participants': [
            {'id': 'S1', 'display_name': 'Rahul'},
          ],
        },
      });
      final m = (r as MeetingResponse).meeting;
      expect(m.id, 'm1');
      expect(m.title, 'Release planning');
      expect(m.participants.single.displayName, 'Rahul');
    });

    test('Mom', () {
      final r = Response.fromJson({
        'type': 'Mom',
        'data': {'markdown': '# Notes'},
      });
      expect((r as MomResponse).markdown, '# Notes');
    });

    test('Error', () {
      final r = Response.fromJson({
        'type': 'Error',
        'data': {'message': 'boom'},
      });
      expect((r as ErrorResponse).message, 'boom');
    });

    test('unknown response type throws ProtocolException', () {
      expect(
        () => Response.fromJson({'type': 'Nope', 'data': {}}),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('events decode from the {type, data} shape', () {
    test('JobCompleted carries job + meeting ids', () {
      final e = EngineEvent.fromJson({
        'type': 'JobCompleted',
        'data': {'job_id': 'j1', 'meeting_id': 'm1'},
      });
      expect(e.type, EngineEventType.jobCompleted);
      expect(e.jobId, 'j1');
      expect(e.meetingId, 'm1');
    });

    test('ExtractionProgress carries counters', () {
      final e = EngineEvent.fromJson({
        'type': 'ExtractionProgress',
        'data': {'job_id': 'j1', 'completed': 2, 'total': 5},
      });
      expect(e.type, EngineEventType.extractionProgress);
      expect(e.completed, 2);
      expect(e.total, 5);
    });

    test('TranscriptionProgress carries a float progress', () {
      final e = EngineEvent.fromJson({
        'type': 'TranscriptionProgress',
        'data': {'job_id': 'j1', 'progress': 0.5},
      });
      expect(e.progress, 0.5);
    });

    test('JobFailed carries a message', () {
      final e = EngineEvent.fromJson({
        'type': 'JobFailed',
        'data': {'job_id': 'j1', 'message': 'llm offline'},
      });
      expect(e.type, EngineEventType.jobFailed);
      expect(e.message, 'llm offline');
    });

    test('an unknown event type decodes to `unknown` and does not throw', () {
      final e = EngineEvent.fromJson({
        'type': 'SomeFutureEvent',
        'data': {'job_id': 'j1'},
      });
      expect(e.type, EngineEventType.unknown);
      expect(e.rawType, 'SomeFutureEvent');
      expect(e.jobId, 'j1');
    });
  });
}
