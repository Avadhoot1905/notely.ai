// Dart side of the Notely IPC contract.
//
// This mirrors the Rust `engine/src/ipc/protocol.rs` types. The canonical, language-neutral
// description lives in `packages/protocol`. Keep the two sides in sync: on a protocol change,
// update `packages/protocol`, the Rust `protocol.rs`, and this file together, and bump
// [protocolVersion].

/// Must match `PROTOCOL_VERSION` in the Rust engine. The client refuses to talk to an engine
/// with a mismatched major version.
const int protocolVersion = 1;

/// Requests the app can send to the engine (Flutter → Engine).
sealed class Request {
  const Request();

  /// Serialize into the wire envelope payload.
  Map<String, dynamic> toJson();
}

class StartMeeting extends Request {
  final String? title;
  const StartMeeting({this.title});
  @override
  Map<String, dynamic> toJson() => {
    'type': 'StartMeeting',
    'params': {'title': title},
  };
}

class ImportMeeting extends Request {
  final String sourcePath;
  const ImportMeeting(this.sourcePath);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'ImportMeeting',
    'params': {'source_path': sourcePath},
  };
}

class GetMeeting extends Request {
  final String meetingId;
  const GetMeeting(this.meetingId);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'GetMeeting',
    'params': {'meeting_id': meetingId},
  };
}

class GetTranscript extends Request {
  final String meetingId;
  const GetTranscript(this.meetingId);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'GetTranscript',
    'params': {'meeting_id': meetingId},
  };
}

class GetMom extends Request {
  final String meetingId;
  const GetMom(this.meetingId);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'GetMom',
    'params': {'meeting_id': meetingId},
  };
}

class CancelJob extends Request {
  final String jobId;
  const CancelJob(this.jobId);
  @override
  Map<String, dynamic> toJson() => {
    'type': 'CancelJob',
    'params': {'job_id': jobId},
  };
}

/// Asynchronous events streamed Engine → Flutter during a job. Mirrors
/// `engine/src/ipc/events.rs`.
enum EngineEventType {
  jobCreated,
  transcriptionStarted,
  transcriptionProgress,
  analysisStarted,
  momGenerated,
  jobCompleted,
  jobFailed,
}
