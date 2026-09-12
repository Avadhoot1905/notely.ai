//! The wire contract shared (in spirit) with the Dart client in `apps/desktop/lib/ipc`.
//!
//! Small, versioned, serializable. The canonical human-readable description lives in
//! `packages/protocol` and `docs/ipc.md`.

use serde::{Deserialize, Serialize};

use crate::domain::{Meeting, MeetingId, Transcript};
use crate::pipeline::jobs::{Job, JobId};

/// Bumped on any breaking change to requests, responses, or events. The Dart client must refuse
/// to talk to an engine with a mismatched major version.
pub const PROTOCOL_VERSION: u32 = 1;

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
}

/// Health details.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthInfo {
    pub protocol_version: u32,
    pub engine_ok: bool,
    /// Whether the LLM runtime responded to a health check.
    pub llm_ok: bool,
    pub model: String,
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
    /// The request failed.
    Error {
        message: String,
    },
}
