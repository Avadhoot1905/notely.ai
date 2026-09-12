//! Asynchronous events streamed Engine → Flutter while a job runs.
//!
//! Requests return quickly (often with a [`JobId`]); the actual pipeline progress is
//! reported here so the UI can show live status without blocking.

use serde::{Deserialize, Serialize};

use super::protocol::JobId;

/// Lifecycle + progress events for a job. Mirrors the pipeline stages in `docs/pipeline.md`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Event {
    JobCreated {
        job_id: JobId,
    },
    TranscriptionStarted {
        job_id: JobId,
    },
    /// `progress` is 0.0..=1.0.
    TranscriptionProgress {
        job_id: JobId,
        progress: f32,
    },
    AnalysisStarted {
        job_id: JobId,
    },
    MomGenerated {
        job_id: JobId,
        meeting_id: String,
    },
    JobCompleted {
        job_id: JobId,
    },
    JobFailed {
        job_id: JobId,
        message: String,
    },
}
