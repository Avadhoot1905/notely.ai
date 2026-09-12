//! Job model: a trackable, cancellable unit of long-running work.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::domain::MeetingId;

/// Identifies a processing job.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct JobId(pub String);

impl JobId {
    pub fn new() -> Self {
        JobId(Uuid::new_v4().to_string())
    }
}

impl Default for JobId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for JobId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Coarse job status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

/// Which pipeline stage a job is in (also drives progress events).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStage {
    Created,
    MediaProcessing,
    Transcription,
    Chunking,
    Extraction,
    Synthesis,
    Validation,
    Rendering,
    Storing,
    Done,
}

/// A tracked pipeline run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub id: JobId,
    pub status: JobStatus,
    pub stage: JobStage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<MeetingId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Job {
    fn new(id: JobId) -> Self {
        Self {
            id,
            status: JobStatus::Queued,
            stage: JobStage::Created,
            meeting_id: None,
            error: None,
        }
    }
}

/// A shared cancellation flag handed to a running pipeline.
#[derive(Clone, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

struct Entry {
    job: Job,
    cancel: CancelFlag,
}

/// In-memory registry of jobs. Thread-safe and cheap to clone.
#[derive(Clone, Default)]
pub struct JobRegistry {
    inner: Arc<Mutex<HashMap<JobId, Entry>>>,
}

impl JobRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Create and register a new job, returning its id and cancel flag.
    pub fn create(&self) -> (JobId, CancelFlag) {
        let id = JobId::new();
        let cancel = CancelFlag::default();
        let mut map = self.inner.lock().expect("job registry poisoned");
        map.insert(
            id.clone(),
            Entry {
                job: Job::new(id.clone()),
                cancel: cancel.clone(),
            },
        );
        (id, cancel)
    }

    pub fn get(&self, id: &JobId) -> Option<Job> {
        self.inner
            .lock()
            .expect("job registry poisoned")
            .get(id)
            .map(|e| e.job.clone())
    }

    /// Request cancellation. Returns false if the job is unknown.
    pub fn request_cancel(&self, id: &JobId) -> bool {
        let map = self.inner.lock().expect("job registry poisoned");
        match map.get(id) {
            Some(entry) => {
                entry.cancel.cancel();
                true
            }
            None => false,
        }
    }

    pub(crate) fn update<F: FnOnce(&mut Job)>(&self, id: &JobId, f: F) {
        if let Some(entry) = self
            .inner
            .lock()
            .expect("job registry poisoned")
            .get_mut(id)
        {
            f(&mut entry.job);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_get_and_cancel() {
        let reg = JobRegistry::new();
        let (id, cancel) = reg.create();
        assert!(reg.get(&id).is_some());
        assert!(!cancel.is_cancelled());
        assert!(reg.request_cancel(&id));
        assert!(cancel.is_cancelled());
        assert!(!reg.request_cancel(&JobId::new()));
    }
}
