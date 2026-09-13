// Dart side of the Notely IPC contract.
//
// This mirrors the Rust `engine/src/ipc/protocol.rs` and `engine/src/ipc/events.rs` types.
// The canonical, language-neutral description lives in `packages/protocol`. Keep the two sides
// in sync: on a protocol change, update `packages/protocol`, the Rust `protocol.rs`/`events.rs`,
// and this file together, and bump [protocolVersion].
//
// The Rust engine is the source of truth. These types are a faithful, strongly-typed mirror of
// its wire shape — nothing here invents fields the engine does not send.

/// Must match `PROTOCOL_VERSION` in the Rust engine. The client refuses to talk to an engine
/// with a mismatched major version.
const int protocolVersion = 1;

// ---------------------------------------------------------------------------
// Domain models (mirror engine/src/domain and pipeline/jobs.rs).
// ---------------------------------------------------------------------------

/// A meeting participant / speaker (mirrors `domain::Participant`).
class Participant {
  final String id;
  final String? displayName;

  const Participant({required this.id, this.displayName});

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
    id: json['id'] as String,
    displayName: json['display_name'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (displayName != null) 'display_name': displayName,
  };
}

/// A contiguous span of recognized speech (mirrors `domain::TranscriptSegment`).
class TranscriptSegment {
  final String? speakerId;
  final double start;
  final double end;
  final String text;
  final String? language;
  final double? confidence;

  const TranscriptSegment({
    this.speakerId,
    required this.start,
    required this.end,
    required this.text,
    this.language,
    this.confidence,
  });

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        speakerId: json['speaker_id'] as String?,
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        text: json['text'] as String,
        language: json['language'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
    if (speakerId != null) 'speaker_id': speakerId,
    'start': start,
    'end': end,
    'text': text,
    if (language != null) 'language': language,
    if (confidence != null) 'confidence': confidence,
  };
}

/// The full ordered transcript for a meeting (mirrors `domain::Transcript`).
class Transcript {
  final List<TranscriptSegment> segments;

  const Transcript({this.segments = const []});

  factory Transcript.fromJson(Map<String, dynamic> json) => Transcript(
    segments: ((json['segments'] as List?) ?? const [])
        .map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'segments': segments.map((s) => s.toJson()).toList(growable: false),
  };
}

/// Meeting metadata (mirrors `domain::Meeting`).
class Meeting {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime? occurredAt;
  final List<Participant> participants;
  final double? durationSeconds;

  const Meeting({
    required this.id,
    required this.title,
    required this.createdAt,
    this.occurredAt,
    this.participants = const [],
    this.durationSeconds,
  });

  factory Meeting.fromJson(Map<String, dynamic> json) => Meeting(
    id: json['id'] as String,
    title: json['title'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    occurredAt: json['occurred_at'] == null
        ? null
        : DateTime.parse(json['occurred_at'] as String),
    participants: ((json['participants'] as List?) ?? const [])
        .map((e) => Participant.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
  );
}

/// Coarse job status (mirrors `pipeline::jobs::JobStatus`).
enum JobStatus {
  queued,
  running,
  completed,
  failed,
  cancelled;

  static JobStatus fromWire(String s) => switch (s) {
    'queued' => JobStatus.queued,
    'running' => JobStatus.running,
    'completed' => JobStatus.completed,
    'failed' => JobStatus.failed,
    'cancelled' => JobStatus.cancelled,
    _ => JobStatus.queued,
  };
}

/// Which pipeline stage a job is in (mirrors `pipeline::jobs::JobStage`).
enum JobStage {
  created,
  mediaProcessing,
  transcription,
  chunking,
  extraction,
  synthesis,
  validation,
  rendering,
  storing,
  done;

  static JobStage fromWire(String s) => switch (s) {
    'created' => JobStage.created,
    'media_processing' => JobStage.mediaProcessing,
    'transcription' => JobStage.transcription,
    'chunking' => JobStage.chunking,
    'extraction' => JobStage.extraction,
    'synthesis' => JobStage.synthesis,
    'validation' => JobStage.validation,
    'rendering' => JobStage.rendering,
    'storing' => JobStage.storing,
    'done' => JobStage.done,
    _ => JobStage.created,
  };
}

/// A tracked pipeline run (mirrors `pipeline::jobs::Job`).
class Job {
  final String id;
  final JobStatus status;
  final JobStage stage;
  final String? meetingId;
  final String? error;

  const Job({
    required this.id,
    required this.status,
    required this.stage,
    this.meetingId,
    this.error,
  });

  factory Job.fromJson(Map<String, dynamic> json) => Job(
    id: json['id'] as String,
    status: JobStatus.fromWire(json['status'] as String),
    stage: JobStage.fromWire(json['stage'] as String),
    meetingId: json['meeting_id'] as String?,
    error: json['error'] as String?,
  );
}

/// Engine + runtime liveness details (mirrors `ipc::protocol::HealthInfo`).
class HealthInfo {
  final int protocolVersion;
  final bool engineOk;
  final bool llmOk;
  final String model;
  final String asrProvider;

  const HealthInfo({
    required this.protocolVersion,
    required this.engineOk,
    required this.llmOk,
    required this.model,
    required this.asrProvider,
  });

  factory HealthInfo.fromJson(Map<String, dynamic> json) => HealthInfo(
    protocolVersion: (json['protocol_version'] as num).toInt(),
    engineOk: json['engine_ok'] as bool,
    llmOk: json['llm_ok'] as bool,
    model: json['model'] as String,
    asrProvider: json['asr_provider'] as String,
  );
}

// ---------------------------------------------------------------------------
// Requests (Flutter -> Engine). Mirrors `ipc::protocol::Request`, which is
// serde-tagged `{ "type": <variant>, "params": { ... } }`. Unit variants
// (Health) carry no `params` (serde omits `content` for unit variants).
// ---------------------------------------------------------------------------

/// What to process into a meeting (mirrors `ipc::protocol::ProcessInput`),
/// serde-tagged internally by `kind`.
sealed class ProcessInput {
  const ProcessInput();
  Map<String, dynamic> toJson();
}

class TranscriptInput extends ProcessInput {
  final String? title;
  final Transcript transcript;
  const TranscriptInput({this.title, required this.transcript});
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'transcript',
    'title': title,
    'transcript': transcript.toJson(),
  };
}

class AudioInput extends ProcessInput {
  final String? title;
  final String path;
  const AudioInput({this.title, required this.path});
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'audio',
    'title': title,
    'path': path,
  };
}

/// Requests the app can send to the engine.
sealed class Request {
  const Request();

  /// The command tag understood by the engine.
  String get type;

  /// The `params` object, or null for unit requests (no `params` on the wire).
  Map<String, dynamic>? get params;

  /// Serialize into the wire envelope payload `{ type, params? }`.
  Map<String, dynamic> toJson() => {
    'type': type,
    if (params != null) 'params': params,
  };
}

/// Liveness check for the engine (and, best-effort, the LLM runtime).
class Health extends Request {
  const Health();
  @override
  String get type => 'Health';
  @override
  Map<String, dynamic>? get params => null;
}

/// Create and run a processing job for a meeting.
class ProcessMeeting extends Request {
  final ProcessInput input;
  const ProcessMeeting(this.input);
  @override
  String get type => 'ProcessMeeting';
  @override
  Map<String, dynamic>? get params => {'input': input.toJson()};
}

/// Fetch a job's current status.
class GetJob extends Request {
  final String jobId;
  const GetJob(this.jobId);
  @override
  String get type => 'GetJob';
  @override
  Map<String, dynamic>? get params => {'job_id': jobId};
}

/// Cancel an in-flight job.
class CancelJob extends Request {
  final String jobId;
  const CancelJob(this.jobId);
  @override
  String get type => 'CancelJob';
  @override
  Map<String, dynamic>? get params => {'job_id': jobId};
}

/// Fetch meeting metadata.
class GetMeeting extends Request {
  final String meetingId;
  const GetMeeting(this.meetingId);
  @override
  String get type => 'GetMeeting';
  @override
  Map<String, dynamic>? get params => {'meeting_id': meetingId};
}

/// Fetch the canonical transcript for a meeting.
class GetTranscript extends Request {
  final String meetingId;
  const GetTranscript(this.meetingId);
  @override
  String get type => 'GetTranscript';
  @override
  Map<String, dynamic>? get params => {'meeting_id': meetingId};
}

/// Fetch the rendered (Markdown) MOM for a meeting.
class GetMom extends Request {
  final String meetingId;
  const GetMom(this.meetingId);
  @override
  String get type => 'GetMom';
  @override
  Map<String, dynamic>? get params => {'meeting_id': meetingId};
}

// ---------------------------------------------------------------------------
// Responses (Engine -> Flutter). Mirrors `ipc::protocol::Response`, which is
// serde-tagged `{ "type": <variant>, "data": { ... } }`.
// ---------------------------------------------------------------------------

/// Raised when a response payload cannot be understood (malformed / unexpected).
class ProtocolException implements Exception {
  final String message;
  const ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

/// An error returned by the engine itself (a known application error).
class EngineError implements Exception {
  final String message;
  const EngineError(this.message);
  @override
  String toString() => 'EngineError: $message';
}

sealed class Response {
  const Response();

  /// Decode a `Response` from the `{ type, data }` payload carried by a
  /// [ResponseEnvelope]. Throws [ProtocolException] on an unknown/invalid shape.
  factory Response.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final data = json['data'];
    switch (type) {
      case 'Health':
        return HealthResponse(
          HealthInfo.fromJson(data as Map<String, dynamic>),
        );
      case 'JobAccepted':
        return JobAcceptedResponse(
          (data as Map<String, dynamic>)['job_id'] as String,
        );
      case 'Job':
        return JobResponse(Job.fromJson(data as Map<String, dynamic>));
      case 'Meeting':
        return MeetingResponse(Meeting.fromJson(data as Map<String, dynamic>));
      case 'Transcript':
        return TranscriptResponse(
          Transcript.fromJson(data as Map<String, dynamic>),
        );
      case 'Mom':
        return MomResponse(
          (data as Map<String, dynamic>)['markdown'] as String,
        );
      case 'Error':
        return ErrorResponse(
          (data as Map<String, dynamic>)['message'] as String,
        );
      default:
        throw ProtocolException('unknown response type: $type');
    }
  }
}

class HealthResponse extends Response {
  final HealthInfo info;
  const HealthResponse(this.info);
}

class JobAcceptedResponse extends Response {
  final String jobId;
  const JobAcceptedResponse(this.jobId);
}

class JobResponse extends Response {
  final Job job;
  const JobResponse(this.job);
}

class MeetingResponse extends Response {
  final Meeting meeting;
  const MeetingResponse(this.meeting);
}

class TranscriptResponse extends Response {
  final Transcript transcript;
  const TranscriptResponse(this.transcript);
}

class MomResponse extends Response {
  final String markdown;
  const MomResponse(this.markdown);
}

class ErrorResponse extends Response {
  final String message;
  const ErrorResponse(this.message);
}

// ---------------------------------------------------------------------------
// Events (Engine -> Flutter). Mirrors `ipc::events::Event`, serde-tagged
// `{ "type": <variant>, "data": { ... } }`, wrapped in an EventEnvelope that
// carries a top-level `event` object.
// ---------------------------------------------------------------------------

/// The kind of an engine event. `unknown` is a forward-compatible fallback so
/// an event the client does not recognize never crashes the app.
enum EngineEventType {
  jobCreated,
  processingStarted,
  mediaProcessingStarted,
  mediaProcessingCompleted,
  transcriptionStarted,
  transcriptionProgress,
  transcriptionCompleted,
  chunkingStarted,
  chunkingCompleted,
  extractionStarted,
  extractionProgress,
  extractionCompleted,
  synthesisStarted,
  synthesisCompleted,
  validationStarted,
  validationCompleted,
  renderingStarted,
  renderingCompleted,
  jobCompleted,
  jobFailed,
  unknown;

  static EngineEventType fromWire(String s) => switch (s) {
    'JobCreated' => EngineEventType.jobCreated,
    'ProcessingStarted' => EngineEventType.processingStarted,
    'MediaProcessingStarted' => EngineEventType.mediaProcessingStarted,
    'MediaProcessingCompleted' => EngineEventType.mediaProcessingCompleted,
    'TranscriptionStarted' => EngineEventType.transcriptionStarted,
    'TranscriptionProgress' => EngineEventType.transcriptionProgress,
    'TranscriptionCompleted' => EngineEventType.transcriptionCompleted,
    'ChunkingStarted' => EngineEventType.chunkingStarted,
    'ChunkingCompleted' => EngineEventType.chunkingCompleted,
    'ExtractionStarted' => EngineEventType.extractionStarted,
    'ExtractionProgress' => EngineEventType.extractionProgress,
    'ExtractionCompleted' => EngineEventType.extractionCompleted,
    'SynthesisStarted' => EngineEventType.synthesisStarted,
    'SynthesisCompleted' => EngineEventType.synthesisCompleted,
    'ValidationStarted' => EngineEventType.validationStarted,
    'ValidationCompleted' => EngineEventType.validationCompleted,
    'RenderingStarted' => EngineEventType.renderingStarted,
    'RenderingCompleted' => EngineEventType.renderingCompleted,
    'JobCompleted' => EngineEventType.jobCompleted,
    'JobFailed' => EngineEventType.jobFailed,
    _ => EngineEventType.unknown,
  };
}

/// A decoded engine event. Every event carries a [jobId]; the remaining fields
/// are populated only for the variants that include them (see events.rs).
class EngineEvent {
  final EngineEventType type;

  /// The raw wire tag, preserved so unknown events remain inspectable/loggable.
  final String rawType;
  final String? jobId;
  final String? meetingId;

  /// 0.0..=1.0 transcription progress (TranscriptionProgress only).
  final double? progress;

  /// Extraction progress counters (ExtractionProgress only).
  final int? completed;
  final int? total;

  /// Chunk count (ChunkingCompleted / ExtractionStarted).
  final int? chunkCount;

  /// Failure message (JobFailed only).
  final String? message;

  const EngineEvent({
    required this.type,
    required this.rawType,
    this.jobId,
    this.meetingId,
    this.progress,
    this.completed,
    this.total,
    this.chunkCount,
    this.message,
  });

  /// Decode from the inner `{ type, data }` event object. Tolerant of unknown
  /// types and missing fields so a malformed or future event never throws.
  factory EngineEvent.fromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] as String?) ?? '';
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    return EngineEvent(
      type: EngineEventType.fromWire(rawType),
      rawType: rawType,
      jobId: data['job_id'] as String?,
      meetingId: data['meeting_id'] as String?,
      progress: (data['progress'] as num?)?.toDouble(),
      completed: (data['completed'] as num?)?.toInt(),
      total: (data['total'] as num?)?.toInt(),
      chunkCount: (data['chunk_count'] as num?)?.toInt(),
      message: data['message'] as String?,
    );
  }
}
