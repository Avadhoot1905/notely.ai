//! Asynchronous events streamed Engine → Flutter while a job runs.
//!
//! Requests return quickly (usually with a [`JobId`]); real pipeline progress is reported here so
//! the UI can show live status without blocking. Every event carries the `job_id` it belongs to.

use serde::{Deserialize, Serialize};

use crate::domain::MeetingId;
use crate::pipeline::jobs::JobId;

/// Lifecycle events for a job. Names mirror the pipeline stages in `docs/pipeline.md`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Event {
    JobCreated {
        job_id: JobId,
    },
    ProcessingStarted {
        job_id: JobId,
        meeting_id: MeetingId,
    },
    TranscriptionStarted {
        job_id: JobId,
    },
    AnalysisStarted {
        job_id: JobId,
    },
    RenderingStarted {
        job_id: JobId,
    },
    JobCompleted {
        job_id: JobId,
        meeting_id: MeetingId,
    },
    JobFailed {
        job_id: JobId,
        message: String,
    },
}

/// Outgoing event wrapper on the wire, so clients can distinguish events from responses
/// (responses carry a `request_id`; events carry an `event`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub protocol_version: u32,
    pub event: Event,
}

impl Event {
    /// The job this event belongs to.
    pub fn job_id(&self) -> &JobId {
        match self {
            Event::JobCreated { job_id }
            | Event::ProcessingStarted { job_id, .. }
            | Event::TranscriptionStarted { job_id }
            | Event::AnalysisStarted { job_id }
            | Event::RenderingStarted { job_id }
            | Event::JobCompleted { job_id, .. }
            | Event::JobFailed { job_id, .. } => job_id,
        }
    }
}
