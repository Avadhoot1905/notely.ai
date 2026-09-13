//! The wire contract shared (in spirit) with the Dart client in `apps/desktop/lib/ipc`.
//!
//! Small, versioned, serializable. The canonical human-readable description lives in
//! `packages/protocol` and `docs/ipc.md`.

use serde::{Deserialize, Serialize};

use crate::domain::{AskAnswer, Meeting, MeetingId, MeetingSummary, SearchHit, Transcript};
use crate::pipeline::jobs::{Job, JobId};

/// Bumped on any breaking change to requests, responses, or events. The Dart client must refuse
/// to talk to an engine with a mismatched major version.
///
/// v2: added vault-wide `Search`/`Ask` requests and `SearchResults`/`Answer` responses.
/// v3: added `ListMeetings`/`ReprocessMeeting` and the `MeetingList` response (Inbox + retry).
pub const PROTOCOL_VERSION: u32 = 3;

/// Correlates a response with the request that produced it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestId(pub String);

/// A request envelope sent Flutter → Engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestEnvelope {
    pub protocol_version: u32,
    pub request_id: RequestId,
    #[serde(flatten)]
    pub request: Request,
}

/// A response envelope sent Engine → Flutter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseEnvelope {
    pub protocol_version: u32,
    pub request_id: RequestId,
    #[serde(flatten)]
    pub response: Response,
}

/// What to process into a meeting.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProcessInput {
    /// Analyze an already-available transcript (the supported v0 path).
    Transcript {
        title: Option<String>,
        transcript: Transcript,
    },
    /// Process an audio/video file (requires media + ASR, not yet implemented end-to-end).
    Audio { title: Option<String>, path: String },
}

/// Commands the desktop app can issue.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "params")]
pub enum Request {
    /// Liveness check for the engine (and, best-effort, the LLM runtime).
    Health,
    /// Create and run a processing job for a meeting.
    ProcessMeeting { input: ProcessInput },
    /// Fetch a job's current status.
    GetJob { job_id: JobId },
    /// Cancel an in-flight job.
    CancelJob { job_id: JobId },
    /// Fetch meeting metadata.
    GetMeeting { meeting_id: MeetingId },
    /// Fetch the canonical transcript for a meeting.
    GetTranscript { meeting_id: MeetingId },
    /// Fetch the rendered (Markdown) MOM for a meeting.
    GetMom { meeting_id: MeetingId },
    /// Full-text search the user's vault of Markdown notes at `vault_path`.
    Search {
        query: String,
        vault_path: String,
        /// Max hits to return (engine default when absent).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        limit: Option<usize>,
    },
    /// Answer a question grounded in the vault at `vault_path`, with source citations.
    Ask {
        question: String,
        vault_path: String,
    },
    /// List captured meetings with their processing status (powers the Inbox + recovery UI).
    ListMeetings,
    /// Retry AI enrichment for an already-captured meeting from its stored transcript. Idempotent:
    /// reuses the meeting, never re-captures or duplicates. Reports progress via events.
    ReprocessMeeting { meeting_id: MeetingId },
}

/// Health details.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthInfo {
    pub protocol_version: u32,
    pub engine_ok: bool,
    /// Whether the LLM runtime (Ollama) responded to a health check.
    pub llm_ok: bool,
    /// The configured LLM model tag (e.g. "qwen3:1.7b").
    pub model: String,
    /// The configured ASR provider (e.g. "qwen3-asr"), which runs on a separate runtime.
    pub asr_provider: String,
}

/// Immediate responses to a [`Request`]. Long work continues via [`super::events::Event`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Response {
    Health(HealthInfo),
    /// A job was accepted and will report progress via events.
    JobAccepted {
        job_id: JobId,
    },
    Job(Job),
    Meeting(Meeting),
    Transcript(Transcript),
    Mom {
        markdown: String,
    },
    /// Ranked search hits for a [`Request::Search`].
    SearchResults(Vec<SearchHit>),
    /// A source-grounded answer for a [`Request::Ask`].
    Answer(AskAnswer),
    /// Captured meetings + their processing status for a [`Request::ListMeetings`].
    MeetingList(Vec<MeetingSummary>),
    /// The request failed.
    Error {
        message: String,
    },
}
