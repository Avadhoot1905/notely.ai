//! Job model: a unit of long-running work the app can track and cancel.

use serde::{Deserialize, Serialize};

/// Coarse status of a processing job, surfaced to the UI via IPC events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum JobStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

/// A tracked pipeline run for one meeting.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub meeting_id: Option<String>,
    pub status: JobStatus,
    /// 0.0..=1.0 overall progress estimate.
    pub progress: f32,
}
