//! Durable persistence for the job queue.
//!
//! A tiny SQLite table mirroring the in-memory [`JobRegistry`](super::jobs::JobRegistry): every job
//! and every state transition is written here so background work survives a crash or restart. This
//! is deliberately NOT a distributed queue or a retry framework — it is one table on the local disk,
//! read once at startup to requeue whatever was interrupted (see the engine's `recover_jobs`).
//!
//! It lives in its own file (`jobs.db`) alongside the search index, keeping operational metadata
//! separate from the meeting store (the source of truth).

use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

use super::jobs::{Job, JobId, JobKind, JobStage, JobStatus};
use crate::domain::MeetingId;

#[derive(Debug, thiserror::Error)]
pub enum JobStoreError {
    #[error("job store backend error: {0}")]
    Backend(String),
}

fn be<E: std::fmt::Display>(e: E) -> JobStoreError {
    JobStoreError::Backend(e.to_string())
}

/// SQLite-backed job persistence. Cloneable handle sharing one connection. Writes are synchronous
/// and tiny (single-row upserts), which is fine for a local single-user queue.
#[derive(Clone)]
pub struct JobStore {
    conn: Arc<Mutex<Connection>>,
}

impl JobStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, JobStoreError> {
        let conn = Connection::open(path).map_err(be)?;
        Self::from_conn(conn)
    }

    pub fn open_in_memory() -> Result<Self, JobStoreError> {
        let conn = Connection::open_in_memory().map_err(be)?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self, JobStoreError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS jobs (
                 id         TEXT PRIMARY KEY,
                 kind       TEXT NOT NULL,
                 meeting_id TEXT,
                 state      TEXT NOT NULL,
                 stage      TEXT NOT NULL,
                 attempts   INTEGER NOT NULL DEFAULT 0,
                 error      TEXT,
                 created_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             );",
        )
        .map_err(be)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Insert or update a job row from its current in-memory state. `created_at` is preserved on
    /// update; `updated_at` always advances.
    pub fn upsert(&self, job: &Job) -> Result<(), JobStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let guard = self.conn.lock().map_err(be)?;
        guard
            .execute(
                "INSERT INTO jobs (id, kind, meeting_id, state, stage, attempts, error, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                     kind = excluded.kind,
                     meeting_id = excluded.meeting_id,
                     state = excluded.state,
                     stage = excluded.stage,
                     attempts = excluded.attempts,
                     error = excluded.error,
                     updated_at = excluded.updated_at",
                params![
                    job.id.0,
                    enum_str(&job.kind),
                    job.meeting_id.as_ref().map(|m| m.0.clone()),
                    enum_str(&job.status),
                    enum_str(&job.stage),
                    job.attempts as i64,
                    job.error,
                    now,
                ],
            )
            .map_err(be)?;
        Ok(())
    }

    /// All jobs left in a non-terminal state (`queued`/`running`) — i.e. interrupted work to recover.
    pub fn list_unfinished(&self) -> Result<Vec<Job>, JobStoreError> {
        let guard = self.conn.lock().map_err(be)?;
        let mut stmt = guard
            .prepare(
                "SELECT id, kind, meeting_id, state, stage, attempts, error
                 FROM jobs WHERE state IN ('queued','running')
                 ORDER BY created_at",
            )
            .map_err(be)?;
        let rows = stmt
            .query_map([], |row| {
                Ok(Job {
                    id: JobId(row.get::<_, String>(0)?),
                    kind: parse_enum(&row.get::<_, String>(1)?).unwrap_or(JobKind::Process),
                    status: parse_enum(&row.get::<_, String>(3)?).unwrap_or(JobStatus::Queued),
                    stage: parse_enum(&row.get::<_, String>(4)?).unwrap_or(JobStage::Created),
                    meeting_id: row.get::<_, Option<String>>(2)?.map(MeetingId),
                    error: row.get::<_, Option<String>>(6)?,
                    attempts: row.get::<_, i64>(5)?.max(0) as u32,
                })
            })
            .map_err(be)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(be)?);
        }
        Ok(out)
    }
}

/// Serialize a snake_case enum to its stored token (e.g. `JobStatus::Queued` -> `"queued"`).
fn enum_str<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .unwrap_or_default()
}

/// Parse a stored token back into its enum.
fn parse_enum<T: serde::de::DeserializeOwned>(s: &str) -> Option<T> {
    serde_json::from_value(serde_json::Value::String(s.to_string())).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_and_lists_only_unfinished() {
        let store = JobStore::open_in_memory().unwrap();

        let mut running = Job {
            id: JobId::new(),
            kind: JobKind::Reprocess,
            status: JobStatus::Running,
            stage: JobStage::Extraction,
            meeting_id: Some(MeetingId::new()),
            error: None,
            attempts: 0,
        };
        store.upsert(&running).unwrap();

        let done = Job {
            id: JobId::new(),
            kind: JobKind::Process,
            status: JobStatus::Completed,
            stage: JobStage::Done,
            meeting_id: Some(MeetingId::new()),
            error: None,
            attempts: 1,
        };
        store.upsert(&done).unwrap();

        let unfinished = store.list_unfinished().unwrap();
        assert_eq!(unfinished.len(), 1, "only the running job is unfinished");
        assert_eq!(unfinished[0].id, running.id);
        assert_eq!(unfinished[0].kind, JobKind::Reprocess);
        assert_eq!(unfinished[0].meeting_id, running.meeting_id);

        // A terminal transition removes it from the unfinished set (upsert in place).
        running.status = JobStatus::Completed;
        store.upsert(&running).unwrap();
        assert!(store.list_unfinished().unwrap().is_empty());
    }
}
