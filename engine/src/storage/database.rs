//! SQLite-backed [`Store`] — the v0 persistence backend.
//!
//! Embedded, file-based, no external server required. `rusqlite` is synchronous, so blocking calls
//! run on Tokio's blocking pool via [`tokio::task::spawn_blocking`]. The connection is shared
//! behind a mutex; for v0's single-user, low-concurrency workload this is more than sufficient.
//!
//! Artifacts (transcript, Meeting IR, MOM) are stored as text keyed by `(meeting_id, kind)`, so
//! new artifact kinds don't need schema changes.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use rusqlite::{params, Connection, OptionalExtension};

use crate::domain::{Meeting, MeetingId, MeetingIr, Transcript};

use super::repositories::{StorageError, Store};

const ARTIFACT_TRANSCRIPT: &str = "transcript";
const ARTIFACT_MEETING_IR: &str = "meeting_ir";
const ARTIFACT_MOM: &str = "mom";

/// SQLite storage. Cloneable handle sharing one connection.
#[derive(Clone)]
pub struct SqliteStore {
    conn: Arc<Mutex<Connection>>,
}

impl SqliteStore {
    /// Open (creating if needed) a database at `path` and run migrations.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self, StorageError> {
        let conn = Connection::open(path).map_err(be)?;
        Self::from_conn(conn)
    }

    /// Open an in-memory database — used by tests.
    pub fn open_in_memory() -> Result<Self, StorageError> {
        let conn = Connection::open_in_memory().map_err(be)?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self, StorageError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS meetings (
                 id         TEXT PRIMARY KEY,
                 title      TEXT NOT NULL,
                 created_at TEXT NOT NULL,
                 data       TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS artifacts (
                 meeting_id TEXT NOT NULL,
                 kind       TEXT NOT NULL,
                 content    TEXT NOT NULL,
                 PRIMARY KEY (meeting_id, kind)
             );",
        )
        .map_err(be)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Run a closure with the locked connection on the blocking pool.
    async fn with_conn<T, F>(&self, f: F) -> Result<T, StorageError>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T, StorageError> + Send + 'static,
    {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| StorageError::Backend(e.to_string()))?;
            f(&guard)
        })
        .await
        .map_err(|e| StorageError::Backend(e.to_string()))?
    }

    async fn put_artifact(
        &self,
        id: &MeetingId,
        kind: &'static str,
        content: String,
    ) -> Result<(), StorageError> {
        let id = id.0.clone();
        self.with_conn(move |c| {
            c.execute(
                "INSERT INTO artifacts (meeting_id, kind, content) VALUES (?1, ?2, ?3)
                 ON CONFLICT(meeting_id, kind) DO UPDATE SET content = excluded.content",
                params![id, kind, content],
            )
            .map_err(be)?;
            Ok(())
        })
        .await
    }

    async fn get_artifact(
        &self,
        id: &MeetingId,
        kind: &'static str,
    ) -> Result<Option<String>, StorageError> {
        let id = id.0.clone();
        self.with_conn(move |c| {
            c.query_row(
                "SELECT content FROM artifacts WHERE meeting_id = ?1 AND kind = ?2",
                params![id, kind],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(be)
        })
        .await
    }
}

#[async_trait]
impl Store for SqliteStore {
    async fn save_meeting(&self, meeting: &Meeting) -> Result<(), StorageError> {
        let id = meeting.id.0.clone();
        let title = meeting.title.clone();
        let created_at = meeting.created_at.to_rfc3339();
        let data = serde_json::to_string(meeting).map_err(se)?;
        self.with_conn(move |c| {
            c.execute(
                "INSERT INTO meetings (id, title, created_at, data) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(id) DO UPDATE SET title = excluded.title, data = excluded.data",
                params![id, title, created_at, data],
            )
            .map_err(be)?;
            Ok(())
        })
        .await
    }

    async fn get_meeting(&self, id: &MeetingId) -> Result<Option<Meeting>, StorageError> {
        let id = id.0.clone();
        let data: Option<String> = self
            .with_conn(move |c| {
                c.query_row(
                    "SELECT data FROM meetings WHERE id = ?1",
                    params![id],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(be)
            })
            .await?;
        match data {
            Some(json) => Ok(Some(serde_json::from_str(&json).map_err(se)?)),
            None => Ok(None),
        }
    }

    async fn list_meetings(&self) -> Result<Vec<Meeting>, StorageError> {
        let rows: Vec<String> = self
            .with_conn(|c| {
                let mut stmt = c
                    .prepare("SELECT data FROM meetings ORDER BY created_at DESC")
                    .map_err(be)?;
                let iter = stmt
                    .query_map([], |row| row.get::<_, String>(0))
                    .map_err(be)?;
                let mut out = Vec::new();
                for r in iter {
                    out.push(r.map_err(be)?);
                }
                Ok(out)
            })
            .await?;
        rows.into_iter()
            .map(|json| serde_json::from_str(&json).map_err(se))
            .collect()
    }

    async fn save_transcript(
        &self,
        id: &MeetingId,
        transcript: &Transcript,
    ) -> Result<(), StorageError> {
        let content = serde_json::to_string(transcript).map_err(se)?;
        self.put_artifact(id, ARTIFACT_TRANSCRIPT, content).await
    }

    async fn get_transcript(&self, id: &MeetingId) -> Result<Option<Transcript>, StorageError> {
        match self.get_artifact(id, ARTIFACT_TRANSCRIPT).await? {
            Some(json) => Ok(Some(serde_json::from_str(&json).map_err(se)?)),
            None => Ok(None),
        }
    }

    async fn save_meeting_ir(&self, id: &MeetingId, ir: &MeetingIr) -> Result<(), StorageError> {
        let content = serde_json::to_string(ir).map_err(se)?;
        self.put_artifact(id, ARTIFACT_MEETING_IR, content).await
    }

    async fn get_meeting_ir(&self, id: &MeetingId) -> Result<Option<MeetingIr>, StorageError> {
        match self.get_artifact(id, ARTIFACT_MEETING_IR).await? {
            Some(json) => Ok(Some(serde_json::from_str(&json).map_err(se)?)),
            None => Ok(None),
        }
    }

    async fn save_mom(&self, id: &MeetingId, mom: &str) -> Result<(), StorageError> {
        self.put_artifact(id, ARTIFACT_MOM, mom.to_string()).await
    }

    async fn get_mom(&self, id: &MeetingId) -> Result<Option<String>, StorageError> {
        self.get_artifact(id, ARTIFACT_MOM).await
    }
}

fn be<E: std::fmt::Display>(e: E) -> StorageError {
    StorageError::Backend(e.to_string())
}
fn se<E: std::fmt::Display>(e: E) -> StorageError {
    StorageError::Serde(e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Meeting, MeetingIr};

    #[tokio::test]
    async fn round_trips_meeting_and_artifacts() {
        let store = SqliteStore::open_in_memory().unwrap();
        let meeting = Meeting::new("Planning");
        store.save_meeting(&meeting).await.unwrap();

        let got = store.get_meeting(&meeting.id).await.unwrap().unwrap();
        assert_eq!(got.title, "Planning");

        let ir = MeetingIr {
            summary: "done".into(),
            ..Default::default()
        };
        store.save_meeting_ir(&meeting.id, &ir).await.unwrap();
        assert_eq!(
            store.get_meeting_ir(&meeting.id).await.unwrap().unwrap(),
            ir
        );

        store.save_mom(&meeting.id, "# MOM").await.unwrap();
        assert_eq!(
            store.get_mom(&meeting.id).await.unwrap().as_deref(),
            Some("# MOM")
        );

        let all = store.list_meetings().await.unwrap();
        assert_eq!(all.len(), 1);
    }

    #[tokio::test]
    async fn upsert_overwrites() {
        let store = SqliteStore::open_in_memory().unwrap();
        let id = MeetingId::new();
        store.save_mom(&id, "one").await.unwrap();
        store.save_mom(&id, "two").await.unwrap();
        assert_eq!(store.get_mom(&id).await.unwrap().as_deref(), Some("two"));
    }
}
