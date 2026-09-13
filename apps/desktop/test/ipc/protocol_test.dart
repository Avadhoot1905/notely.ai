// Unit tests for the Dart side of the IPC protocol: request serialization, response decoding,
// and event decoding. These pin the wire shape against engine/src/ipc/protocol.rs + events.rs.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/ipc/protocol.dart';

void main() {
  test('protocol version matches the engine contract', () {
    // Must be bumped in lockstep with PROTOCOL_VERSION in engine/src/ipc/protocol.rs.
    expect(protocolVersion, 3);
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

    test('Search carries query, vault_path, and optional limit', () {
      expect(
        const Search(query: 'postgres', vaultPath: '/vault', limit: 5).toJson(),
        {
          'type': 'Search',
          'params': {'query': 'postgres', 'vault_path': '/vault', 'limit': 5},
        },
      );
      // limit is omitted when null so the engine applies its default.
      expect(const Search(query: 'q', vaultPath: '/v').toJson(), {
        'type': 'Search',
        'params': {'query': 'q', 'vault_path': '/v'},
      });
    });

    test('Ask carries question and vault_path', () {
      expect(const Ask(question: 'what db?', vaultPath: '/vault').toJson(), {
        'type': 'Ask',
        'params': {'question': 'what db?', 'vault_path': '/vault'},
      });
    });

    test('ListMeetings is a bare tag; ReprocessMeeting carries meeting_id', () {
      expect(const ListMeetings().toJson(), {'type': 'ListMeetings'});
      expect(const ReprocessMeeting('m1').toJson(), {
        'type': 'ReprocessMeeting',
        'params': {'meeting_id': 'm1'},
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

    test('SearchResults decodes a list of hits', () {
      final r = Response.fromJson({
        'type': 'SearchResults',
        'data': [
          {
            'path': '/vault/arch.md',
            'title': 'Architecture',
            'start_line': 2,
            'end_line': 4,
            'snippet': 'We chose PostgreSQL…',
          },
        ],
      });
      final hits = (r as SearchResultsResponse).hits;
      expect(hits.single.path, '/vault/arch.md');
      expect(hits.single.title, 'Architecture');
      expect(hits.single.startLine, 2);
      expect(hits.single.endLine, 4);
    });

    test('Answer decodes text, files_read, and citations', () {
      final r = Response.fromJson({
        'type': 'Answer',
        'data': {
          'text': 'PostgreSQL was chosen [1].',
          'files_read': ['/vault/arch.md'],
          'citations': [
            {
              'path': '/vault/arch.md',
              'start_line': 2,
              'end_line': 4,
              'snippet': 'We chose PostgreSQL…',
            },
          ],
        },
      });
      final a = (r as AnswerResponse).answer;
      expect(a.text, 'PostgreSQL was chosen [1].');
      expect(a.filesRead, ['/vault/arch.md']);
      expect(a.citations.single.startLine, 2);
    });

    test('MeetingList decodes meetings with their processing status', () {
      final r = Response.fromJson({
        'type': 'MeetingList',
        'data': [
          {
            'meeting': {
              'id': 'm1',
              'title': 'Project X',
              'created_at': '2026-09-13T10:42:00Z',
            },
            'status': {
              'state': 'deferred',
              'failure_kind': 'temporary',
              'error': 'llm offline',
            },
          },
          {
            'meeting': {
              'id': 'm2',
              'title': 'Legacy',
              'created_at': '2026-09-13T09:00:00Z',
            },
          },
        ],
      });
      final list = (r as MeetingListResponse).meetings;
      expect(list.length, 2);
      expect(list[0].meeting.id, 'm1');
      expect(list[0].status!.state, ProcessingState.deferred);
      expect(list[0].status!.isRetryable, isTrue);
      // A meeting without a stored status decodes with a null status (predates the layer).
      expect(list[1].status, isNull);
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
