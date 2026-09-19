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
///
/// v2: added vault-wide `Search`/`Ask` requests and `SearchResults`/`Answer` responses.
/// v3: added `ListMeetings`/`ReprocessMeeting` and the `MeetingList` response (Inbox + retry).
/// v4: added the Knowledge Space (`GetKnowledgeMap`) and external sources — Slack/Teams —
///     (`ListSourceChannels`/`ImportSource`/`ListSources`/`DisconnectSource`).
const int protocolVersion = 5;

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

/// Where a capture's AI enrichment stands (mirrors `domain::ProcessingState`).
enum ProcessingState {
  processing,
  ready,
  deferred,
  failed,
  unknown;

  static ProcessingState fromWire(String s) => switch (s) {
    'processing' => ProcessingState.processing,
    'ready' => ProcessingState.ready,
    'deferred' => ProcessingState.deferred,
    'failed' => ProcessingState.failed,
    _ => ProcessingState.unknown,
  };
}

/// Whether a failure is worth a one-click retry (mirrors `domain::FailureKind`).
enum FailureKind {
  temporary,
  permanent,
  unknown;

  static FailureKind fromWire(String? s) => switch (s) {
    'temporary' => FailureKind.temporary,
    'permanent' => FailureKind.permanent,
    _ => FailureKind.unknown,
  };
}

/// A capture's durable processing status (mirrors `domain::ProcessingStatus`).
class ProcessingStatus {
  final ProcessingState state;
  final FailureKind? failureKind;
  final String? error;

  const ProcessingStatus({required this.state, this.failureKind, this.error});

  /// A one-click retry makes sense for anything deferred, plus temporary failures.
  bool get isRetryable =>
      state == ProcessingState.deferred ||
      (state == ProcessingState.failed && failureKind == FailureKind.temporary);

  factory ProcessingStatus.fromJson(Map<String, dynamic> json) =>
      ProcessingStatus(
        state: ProcessingState.fromWire(json['state'] as String? ?? ''),
        failureKind: json['failure_kind'] == null
            ? null
            : FailureKind.fromWire(json['failure_kind'] as String?),
        error: json['error'] as String?,
      );
}

/// A captured meeting paired with its enrichment status (mirrors `domain::MeetingSummary`).
class MeetingSummary {
  final Meeting meeting;
  final ProcessingStatus? status;

  const MeetingSummary({required this.meeting, this.status});

  factory MeetingSummary.fromJson(Map<String, dynamic> json) => MeetingSummary(
    meeting: Meeting.fromJson(json['meeting'] as Map<String, dynamic>),
    status: json['status'] == null
        ? null
        : ProcessingStatus.fromJson(json['status'] as Map<String, dynamic>),
  );
}

// ---------------------------------------------------------------------------
// Knowledge Space (mirror engine/src/domain/knowledge_map.rs). All coordinates
// are normalized to [0,1]; the renderer lays them out at any size.
// ---------------------------------------------------------------------------

/// A conceptual region ("hill"/domain) of the knowledge landscape.
class KnowledgeRegion {
  final int id;
  final String label;
  final double x;
  final double y;
  final double radius;
  final double mass;
  final int conceptCount;
  final int docCount;
  final int rank;
  final List<String> sources;

  const KnowledgeRegion({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.radius,
    required this.mass,
    required this.conceptCount,
    required this.docCount,
    required this.rank,
    required this.sources,
  });

  factory KnowledgeRegion.fromJson(Map<String, dynamic> json) =>
      KnowledgeRegion(
        id: (json['id'] as num).toInt(),
        label: json['label'] as String? ?? '',
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        radius: (json['radius'] as num).toDouble(),
        mass: (json['mass'] as num).toDouble(),
        conceptCount: (json['concept_count'] as num?)?.toInt() ?? 0,
        docCount: (json['doc_count'] as num?)?.toInt() ?? 0,
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        sources:
            (json['sources'] as List?)?.whereType<String>().toList() ??
            const [],
      );
}

/// A single concept — a peak in the landscape. [term] is a real searchable token.
class KnowledgeConcept {
  final int regionId;
  final String term;
  final double x;
  final double y;
  final double mass;
  final int docCount;
  final int rank;
  final List<String> sources;

  const KnowledgeConcept({
    required this.regionId,
    required this.term,
    required this.x,
    required this.y,
    required this.mass,
    required this.docCount,
    required this.rank,
    required this.sources,
  });

  factory KnowledgeConcept.fromJson(Map<String, dynamic> json) =>
      KnowledgeConcept(
        regionId: (json['region_id'] as num).toInt(),
        term: json['term'] as String? ?? '',
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        mass: (json['mass'] as num).toDouble(),
        docCount: (json['doc_count'] as num?)?.toInt() ?? 0,
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        sources:
            (json['sources'] as List?)?.whereType<String>().toList() ??
            const [],
      );
}

/// Corpus-level facts about how the map was derived.
class KnowledgeMapStats {
  final int noteCount;
  final int conceptCount;
  final int regionCount;
  final bool truncated;

  const KnowledgeMapStats({
    this.noteCount = 0,
    this.conceptCount = 0,
    this.regionCount = 0,
    this.truncated = false,
  });

  factory KnowledgeMapStats.fromJson(Map<String, dynamic> json) =>
      KnowledgeMapStats(
        noteCount: (json['note_count'] as num?)?.toInt() ?? 0,
        conceptCount: (json['concept_count'] as num?)?.toInt() ?? 0,
        regionCount: (json['region_count'] as num?)?.toInt() ?? 0,
        truncated: json['truncated'] as bool? ?? false,
      );
}

/// The derived Knowledge Space (mirrors `domain::KnowledgeMap`).
class KnowledgeMap {
  final List<KnowledgeRegion> regions;
  final List<KnowledgeConcept> concepts;
  final KnowledgeMapStats stats;

  const KnowledgeMap({
    this.regions = const [],
    this.concepts = const [],
    this.stats = const KnowledgeMapStats(),
  });

  bool get isEmpty => concepts.isEmpty;

  factory KnowledgeMap.fromJson(Map<String, dynamic> json) => KnowledgeMap(
    regions:
        (json['regions'] as List?)
            ?.map((e) => KnowledgeRegion.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
    concepts:
        (json['concepts'] as List?)
            ?.map((e) => KnowledgeConcept.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
    stats: json['stats'] == null
        ? const KnowledgeMapStats()
        : KnowledgeMapStats.fromJson(json['stats'] as Map<String, dynamic>),
  );
}

// ---------------------------------------------------------------------------
// External sources — Slack/Teams (mirror engine/src/sources/model.rs).
// ---------------------------------------------------------------------------

/// A selectable channel/conversation within a source.
class SourceChannel {
  final String id;
  final String name;
  final String? purpose;
  final int? memberCount;

  const SourceChannel({
    required this.id,
    required this.name,
    this.purpose,
    this.memberCount,
  });

  factory SourceChannel.fromJson(Map<String, dynamic> json) => SourceChannel(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    purpose: json['purpose'] as String?,
    memberCount: (json['member_count'] as num?)?.toInt(),
  );
}

/// The explicit, bounded scope of an import.
class ImportScope {
  final List<String> channelIds;
  final String? since;
  final int? maxMessages;

  const ImportScope({required this.channelIds, this.since, this.maxMessages});

  Map<String, dynamic> toJson() => {
    'channel_ids': channelIds,
    if (since != null) 'since': since,
    if (maxMessages != null) 'max_messages': maxMessages,
  };
}

/// The outcome of an import (mirrors `sources::model::ImportSummary`).
class ImportSummary {
  final int channelsImported;
  final int messagesImported;
  final int messagesSkipped;
  final int documentsWritten;
  final List<String> warnings;

  const ImportSummary({
    this.channelsImported = 0,
    this.messagesImported = 0,
    this.messagesSkipped = 0,
    this.documentsWritten = 0,
    this.warnings = const [],
  });

  factory ImportSummary.fromJson(Map<String, dynamic> json) => ImportSummary(
    channelsImported: (json['channels_imported'] as num?)?.toInt() ?? 0,
    messagesImported: (json['messages_imported'] as num?)?.toInt() ?? 0,
    messagesSkipped: (json['messages_skipped'] as num?)?.toInt() ?? 0,
    documentsWritten: (json['documents_written'] as num?)?.toInt() ?? 0,
    warnings:
        (json['warnings'] as List?)?.whereType<String>().toList() ?? const [],
  );
}

/// A connected external source and its import summary (mirrors `sources::model::ConnectedSource`).
class ConnectedSource {
  final String kind; // 'slack' | 'teams'
  final String workspace;
  final String folder;
  final String? lastImportedAt;
  final int documentCount;
  final List<String> importedChannels;

  const ConnectedSource({
    required this.kind,
    required this.workspace,
    required this.folder,
    this.lastImportedAt,
    this.documentCount = 0,
    this.importedChannels = const [],
  });

  factory ConnectedSource.fromJson(Map<String, dynamic> json) =>
      ConnectedSource(
        kind: json['kind'] as String? ?? '',
        workspace: json['workspace'] as String? ?? '',
        folder: json['folder'] as String? ?? '',
        lastImportedAt: json['last_imported_at'] as String?,
        documentCount: (json['document_count'] as num?)?.toInt() ?? 0,
        importedChannels:
            (json['imported_channels'] as List?)
                ?.whereType<String>()
                .toList() ??
            const [],
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

/// Synchronously transcribe one small audio file (a live speech segment); returns a [Transcript].
/// Ephemeral: the engine creates no job and persists nothing (the authoritative transcript still
/// comes from the full-audio `ProcessMeeting` pass at stop()).
class TranscribeChunk extends Request {
  final String path;
  const TranscribeChunk(this.path);
  @override
  String get type => 'TranscribeChunk';
  @override
  Map<String, dynamic>? get params => {'path': path};
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

/// Full-text search the user's vault of Markdown notes rooted at [vaultPath].
class Search extends Request {
  final String query;
  final String vaultPath;
  final int? limit;
  const Search({required this.query, required this.vaultPath, this.limit});
  @override
  String get type => 'Search';
  @override
  Map<String, dynamic>? get params => {
    'query': query,
    'vault_path': vaultPath,
    if (limit != null) 'limit': limit,
  };
}

/// Ask a question grounded in the vault rooted at [vaultPath]; the answer carries citations.
class Ask extends Request {
  final String question;
  final String vaultPath;
  const Ask({required this.question, required this.vaultPath});
  @override
  String get type => 'Ask';
  @override
  Map<String, dynamic>? get params => {
    'question': question,
    'vault_path': vaultPath,
  };
}

/// List captured meetings with their processing status (Inbox + recovery UI).
class ListMeetings extends Request {
  const ListMeetings();
  @override
  String get type => 'ListMeetings';
  @override
  Map<String, dynamic>? get params => null;
}

/// Retry AI enrichment for an already-captured meeting from its stored transcript. Idempotent:
/// the engine reuses the meeting, so retrying never re-captures or duplicates.
class ReprocessMeeting extends Request {
  final String meetingId;
  const ReprocessMeeting(this.meetingId);
  @override
  String get type => 'ReprocessMeeting';
  @override
  Map<String, dynamic>? get params => {'meeting_id': meetingId};
}

/// Derive the Knowledge Space (semantic-topographic map) for the vault at [vaultPath].
class GetKnowledgeMap extends Request {
  final String vaultPath;
  const GetKnowledgeMap(this.vaultPath);
  @override
  String get type => 'GetKnowledgeMap';
  @override
  Map<String, dynamic>? get params => {'vault_path': vaultPath};
}

/// List importable channels for an external source. [token] is used in-memory only by the engine
/// and never persisted.
class ListSourceChannels extends Request {
  final String kind;
  final String token;
  final String baseUrl;
  const ListSourceChannels({
    required this.kind,
    required this.token,
    this.baseUrl = '',
  });
  @override
  String get type => 'ListSourceChannels';
  @override
  Map<String, dynamic>? get params => {
    'kind': kind,
    'token': token,
    if (baseUrl.isNotEmpty) 'base_url': baseUrl,
  };
}

/// Import selected channels from an external source into the vault. [token] is used in-memory only.
class ImportSource extends Request {
  final String kind;
  final String token;
  final String baseUrl;
  final String vaultPath;
  final ImportScope scope;
  const ImportSource({
    required this.kind,
    required this.token,
    this.baseUrl = '',
    required this.vaultPath,
    required this.scope,
  });
  @override
  String get type => 'ImportSource';
  @override
  Map<String, dynamic>? get params => {
    'kind': kind,
    'token': token,
    if (baseUrl.isNotEmpty) 'base_url': baseUrl,
    'vault_path': vaultPath,
    'scope': scope.toJson(),
  };
}

/// List connected sources and what has been imported.
class ListSources extends Request {
  const ListSources();
  @override
  String get type => 'ListSources';
  @override
  Map<String, dynamic>? get params => null;
}

/// Disconnect a source; optionally delete its imported Markdown from the vault.
class DisconnectSource extends Request {
  final String kind;
  final String vaultPath;
  final bool removeImported;
  const DisconnectSource({
    required this.kind,
    required this.vaultPath,
    this.removeImported = false,
  });
  @override
  String get type => 'DisconnectSource';
  @override
  Map<String, dynamic>? get params => {
    'kind': kind,
    'vault_path': vaultPath,
    'remove_imported': removeImported,
  };
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
      case 'SearchResults':
        return SearchResultsResponse(
          (data as List)
              .map((e) => EngineSearchHit.fromJson(e as Map<String, dynamic>))
              .toList(growable: false),
        );
      case 'Answer':
        return AnswerResponse(
          EngineAnswer.fromJson(data as Map<String, dynamic>),
        );
      case 'MeetingList':
        return MeetingListResponse(
          (data as List)
              .map((e) => MeetingSummary.fromJson(e as Map<String, dynamic>))
              .toList(growable: false),
        );
      case 'KnowledgeMap':
        return KnowledgeMapResponse(
          KnowledgeMap.fromJson(data as Map<String, dynamic>),
        );
      case 'SourceChannels':
        final d = data as Map<String, dynamic>;
        return SourceChannelsResponse(
          workspace: d['workspace'] as String? ?? '',
          channels: (d['channels'] as List? ?? const [])
              .map((e) => SourceChannel.fromJson(e as Map<String, dynamic>))
              .toList(growable: false),
        );
      case 'ImportResult':
        return ImportResultResponse(
          ImportSummary.fromJson(data as Map<String, dynamic>),
        );
      case 'Sources':
        return SourcesResponse(
          (data as List? ?? const [])
              .map((e) => ConnectedSource.fromJson(e as Map<String, dynamic>))
              .toList(growable: false),
        );
      case 'Ok':
        // Unit variant: serde omits `data` for it, so none is expected here.
        return const OkResponse();
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

/// A ranked search hit (mirrors `domain::SearchHit`). Line indices are 0-based, inclusive.
class EngineSearchHit {
  final String path;
  final String title;
  final int startLine;
  final int endLine;
  final String snippet;

  const EngineSearchHit({
    required this.path,
    required this.title,
    required this.startLine,
    required this.endLine,
    required this.snippet,
  });

  factory EngineSearchHit.fromJson(Map<String, dynamic> json) =>
      EngineSearchHit(
        path: json['path'] as String,
        title: json['title'] as String? ?? '',
        startLine: (json['start_line'] as num?)?.toInt() ?? 0,
        endLine: (json['end_line'] as num?)?.toInt() ?? 0,
        snippet: json['snippet'] as String? ?? '',
      );
}

/// A cited passage backing an [EngineAnswer] (mirrors `domain::Citation`).
class EngineCitation {
  final String path;
  final int startLine;
  final int endLine;
  final String snippet;

  const EngineCitation({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.snippet,
  });

  factory EngineCitation.fromJson(Map<String, dynamic> json) => EngineCitation(
    path: json['path'] as String,
    startLine: (json['start_line'] as num?)?.toInt() ?? 0,
    endLine: (json['end_line'] as num?)?.toInt() ?? 0,
    snippet: json['snippet'] as String? ?? '',
  );
}

/// A source-grounded answer (mirrors `domain::AskAnswer`). The [text] may contain `[n]` markers
/// (1-based) that reference [citations].
class EngineAnswer {
  final String text;
  final List<String> filesRead;
  final List<EngineCitation> citations;

  const EngineAnswer({
    required this.text,
    required this.filesRead,
    required this.citations,
  });

  factory EngineAnswer.fromJson(Map<String, dynamic> json) => EngineAnswer(
    text: json['text'] as String? ?? '',
    filesRead:
        (json['files_read'] as List?)?.whereType<String>().toList() ?? const [],
    citations:
        (json['citations'] as List?)
            ?.map((e) => EngineCitation.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
  );
}

class SearchResultsResponse extends Response {
  final List<EngineSearchHit> hits;
  const SearchResultsResponse(this.hits);
}

class AnswerResponse extends Response {
  final EngineAnswer answer;
  const AnswerResponse(this.answer);
}

class MeetingListResponse extends Response {
  final List<MeetingSummary> meetings;
  const MeetingListResponse(this.meetings);
}

class KnowledgeMapResponse extends Response {
  final KnowledgeMap map;
  const KnowledgeMapResponse(this.map);
}

class SourceChannelsResponse extends Response {
  final String workspace;
  final List<SourceChannel> channels;
  const SourceChannelsResponse({
    required this.workspace,
    required this.channels,
  });
}

class ImportResultResponse extends Response {
  final ImportSummary summary;
  const ImportResultResponse(this.summary);
}

class SourcesResponse extends Response {
  final List<ConnectedSource> sources;
  const SourcesResponse(this.sources);
}

/// A source-mutating request (import/disconnect) succeeded with nothing else to return.
class OkResponse extends Response {
  const OkResponse();
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
