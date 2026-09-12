//! The wire contract shared (in spirit) with the Dart client in `apps/desktop/lib/ipc`.
//!
//! Keep this small and boring: a versioned envelope, a request enum, a response enum.
//! The canonical human-readable description lives in `packages/protocol` and `docs/ipc.md`.

use serde::{Deserialize, Serialize};

/// Bumped on any breaking change to requests, responses, or events.
/// The Dart client must refuse to talk to an engine with a mismatched major version.
pub const PROTOCOL_VERSION: u32 = 1;

/// Correlates a response with the request that produced it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestId(pub String);

/// Identifies a long-running processing job so the app can track progress and cancel it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobId(pub String);

/// A request envelope sent Flutter → Engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope<T> {
    pub protocol_version: u32,
    pub request_id: RequestId,
    pub payload: T,
}

/// Commands the desktop app can issue. Deliberately minimal for v0.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "params")]
pub enum Request {
    /// Begin recording/processing a new meeting.
    StartMeeting { title: Option<String> },
    /// Import an existing audio/transcript file as a meeting.
    ImportMeeting { source_path: String },
    /// Fetch meeting metadata.
    GetMeeting { meeting_id: String },
    /// Fetch the canonical transcript for a meeting.
    GetTranscript { meeting_id: String },
    /// Fetch the rendered Minutes of Meeting for a meeting.
    GetMom { meeting_id: String },
    /// Cancel an in-flight job.
    CancelJob { job_id: JobId },
}

/// Immediate responses to a [`Request`]. Long work continues via [`super::events`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Response {
    /// A job was accepted and will report progress via events.
    JobAccepted { job_id: JobId },
    /// A synchronous payload (serialized domain data) is returned inline.
    Data { json: serde_json::Value },
    /// The request failed.
    Error { message: String },
}
