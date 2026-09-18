//! Job model: a trackable, cancellable unit of long-running work.
//!
//! The registry is in-memory for fast lookups, but every create/transition is mirrored to an
//! optional durable [`JobStore`] so background work survives a crash/restart (see
//! [`super::job_store`] and the engine's startup recovery). Persistence is best-effort and never
//! blocks or fails an operation — losing the queue file only costs recoverability, not correctness.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::job_store::JobStore;
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

/// What kind of work a job performs — recorded so startup recovery knows how to resume it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobKind {
    /// Full capture → enrichment for a new meeting.
    #[default]
    Process,
    /// Re-run enrichment for an existing meeting from its stored transcript.
    Reprocess,
    /// Background embedding/indexing of the vault (not tied to a meeting).
    Embedding,
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

impl JobStatus {
    /// Whether the job has reached a terminal state (no further work will happen).
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            JobStatus::Completed | JobStatus::Failed | JobStatus::Cancelled
        )
    }
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
    #[serde(default)]
    pub kind: JobKind,
    pub status: JobStatus,
    pub stage: JobStage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<MeetingId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// How many times this job has been attempted (incremented by startup recovery on requeue).
    #[serde(default)]
    pub attempts: u32,
}

impl Job {
    fn new(id: JobId, kind: JobKind) -> Self {
        Self {
            id,
            kind,
            status: JobStatus::Queued,
            stage: JobStage::Created,
            meeting_id: None,
            error: None,
            attempts: 0,
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

/// In-memory registry of jobs, optionally mirrored to a durable [`JobStore`]. Thread-safe and cheap
/// to clone.
#[derive(Clone, Default)]
pub struct JobRegistry {
    inner: Arc<Mutex<HashMap<JobId, Entry>>>,
    /// Durable backing store. `None` => in-memory only (tests / degraded startup).
    store: Option<JobStore>,
}

impl JobRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a registry backed by a durable [`JobStore`] so jobs survive restarts.
    pub fn with_store(store: JobStore) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            store: Some(store),
        }
    }

    /// Create and register a new job of `kind`, returning its id and cancel flag.
    pub fn create(&self, kind: JobKind) -> (JobId, CancelFlag) {
        let id = JobId::new();
        let cancel = CancelFlag::default();
        let job = Job::new(id.clone(), kind);
        self.persist(&job);
        let mut map = self.inner.lock().expect("job registry poisoned");
        map.insert(
            id.clone(),
            Entry {
                job,
                cancel: cancel.clone(),
            },
        );
        (id, cancel)
    }

    /// Re-register a job recovered from the durable store (already has an id/kind/attempts). Used by
    /// startup recovery so an in-flight cancel and status lookups work for the resumed run.
    pub fn reinsert(&self, job: Job) -> CancelFlag {
        let cancel = CancelFlag::default();
        self.persist(&job);
        let mut map = self.inner.lock().expect("job registry poisoned");
        map.insert(
            job.id.clone(),
            Entry {
                job,
                cancel: cancel.clone(),
            },
        );
        cancel
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
        let snapshot = {
            let mut map = self.inner.lock().expect("job registry poisoned");
            match map.get_mut(id) {
                Some(entry) => {
                    f(&mut entry.job);
                    Some(entry.job.clone())
                }
                None => None,
            }
        };
        if let Some(job) = snapshot {
            self.persist(&job);
        }
    }

    /// Mirror a job's current state to the durable store, if one is configured. Best-effort: a
    /// persistence failure is logged and swallowed so it can never break the in-memory pipeline.
    fn persist(&self, job: &Job) {
        if let Some(store) = &self.store {
            if let Err(e) = store.upsert(job) {
                tracing::warn!("failed to persist job {}: {e}", job.id);
            }
        }
    }

    /// The durable store, if any (for startup recovery).
    pub fn store(&self) -> Option<&JobStore> {
        self.store.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_get_and_cancel() {
        let reg = JobRegistry::new();
        let (id, cancel) = reg.create(JobKind::Process);
        assert!(reg.get(&id).is_some());
        assert!(!cancel.is_cancelled());
        assert!(reg.request_cancel(&id));
        assert!(cancel.is_cancelled());
        assert!(!reg.request_cancel(&JobId::new()));
    }
}
