//! Durable, **non-secret** bookkeeping for connected sources.
//!
//! This remembers *what* was connected and imported — kind, workspace label, folder, channels, and
//! a per-message ledger for idempotent re-import — so the UI can show "what's connected / what was
//! imported" and so a second import never duplicates a message. It deliberately stores **no
//! tokens**: credentials are passed per-request and held only in memory. Losing this DB costs only
//! bookkeeping; the imported knowledge itself lives as Markdown in the vault.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

use super::model::{ConnectedSource, SourceKind};

#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    #[error("source registry error: {0}")]
    Backend(String),
}

fn be<E: std::fmt::Display>(e: E) -> RegistryError {
    RegistryError::Backend(e.to_string())
}

/// SQLite-backed source registry (its own DB, `sources.db`). Cloneable handle over one connection.
#[derive(Clone)]
pub struct SourceRegistry {
    conn: Arc<Mutex<Connection>>,
}

impl SourceRegistry {
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self, RegistryError> {
        Self::from_conn(Connection::open(path).map_err(be)?)
    }

    pub fn open_in_memory() -> Result<Self, RegistryError> {
        Self::from_conn(Connection::open_in_memory().map_err(be)?)
    }

    fn from_conn(conn: Connection) -> Result<Self, RegistryError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS sources (
                 kind             TEXT PRIMARY KEY,
                 workspace        TEXT NOT NULL,
                 folder           TEXT NOT NULL,
                 last_imported_at TEXT
             );
             CREATE TABLE IF NOT EXISTS imported_channels (
                 kind         TEXT NOT NULL,
                 channel_id   TEXT NOT NULL,
                 channel_name TEXT NOT NULL,
                 PRIMARY KEY (kind, channel_id)
             );
             CREATE TABLE IF NOT EXISTS imported_messages (
                 kind       TEXT NOT NULL,
                 channel_id TEXT NOT NULL,
                 message_id TEXT NOT NULL,
                 PRIMARY KEY (kind, channel_id, message_id)
             );",
        )
        .map_err(be)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    async fn with_conn<T, F>(&self, f: F) -> Result<T, RegistryError>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T, RegistryError> + Send + 'static,
    {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| RegistryError::Backend(e.to_string()))?;
            f(&guard)
        })
        .await
        .map_err(|e| RegistryError::Backend(e.to_string()))?
    }

    /// Record (or refresh) a connected source's identity and its vault folder.
    pub async fn upsert_source(
        &self,
        kind: SourceKind,
        workspace: &str,
        folder: &str,
    ) -> Result<(), RegistryError> {
        let (k, w, f) = (
            kind.tag().to_string(),
            workspace.to_string(),
            folder.to_string(),
        );
        self.with_conn(move |c| {
            c.execute(
                "INSERT INTO sources (kind, workspace, folder) VALUES (?1, ?2, ?3)
                 ON CONFLICT(kind) DO UPDATE SET workspace = excluded.workspace, folder = excluded.folder",
                params![k, w, f],
            )
            .map_err(be)?;
            Ok(())
        })
        .await
    }

    /// Which of `ids` have not yet been imported for this channel (read-only; drives dedup).
    pub async fn unseen(
        &self,
        kind: SourceKind,
        channel_id: &str,
        ids: Vec<String>,
    ) -> Result<Vec<String>, RegistryError> {
        let (k, ch) = (kind.tag().to_string(), channel_id.to_string());
        self.with_conn(move |c| {
            let mut known: HashSet<String> = HashSet::new();
            let mut stmt = c
                .prepare(
                    "SELECT message_id FROM imported_messages WHERE kind = ?1 AND channel_id = ?2",
                )
                .map_err(be)?;
            let rows = stmt
                .query_map(params![k, ch], |r| r.get::<_, String>(0))
                .map_err(be)?;
            for r in rows {
                known.insert(r.map_err(be)?);
            }
            Ok(ids.into_iter().filter(|id| !known.contains(id)).collect())
        })
        .await
    }

    /// Commit a channel import: remember the channel, the new message ids, and stamp the source.
    pub async fn record_import(
        &self,
        kind: SourceKind,
        channel_id: &str,
        channel_name: &str,
        new_ids: Vec<String>,
        imported_at: &str,
    ) -> Result<(), RegistryError> {
        let (k, ch, name, at) = (
            kind.tag().to_string(),
            channel_id.to_string(),
            channel_name.to_string(),
            imported_at.to_string(),
        );
        self.with_conn(move |c| {
            c.execute(
                "INSERT INTO imported_channels (kind, channel_id, channel_name) VALUES (?1, ?2, ?3)
                 ON CONFLICT(kind, channel_id) DO UPDATE SET channel_name = excluded.channel_name",
                params![k, ch, name],
            )
            .map_err(be)?;
            for id in &new_ids {
                c.execute(
                    "INSERT OR IGNORE INTO imported_messages (kind, channel_id, message_id) VALUES (?1, ?2, ?3)",
                    params![k, ch, id],
                )
                .map_err(be)?;
            }
            c.execute(
                "UPDATE sources SET last_imported_at = ?2 WHERE kind = ?1",
                params![k, at],
            )
            .map_err(be)?;
            Ok(())
        })
        .await
    }

    /// All connected sources with their import summaries (for the Integrations UI).
    pub async fn list_sources(&self) -> Result<Vec<ConnectedSource>, RegistryError> {
        self.with_conn(|c| {
            let mut out = Vec::new();
            let mut stmt = c
                .prepare("SELECT kind, workspace, folder, last_imported_at FROM sources ORDER BY kind")
                .map_err(be)?;
            let rows = stmt
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, Option<String>>(3)?,
                    ))
                })
                .map_err(be)?;
            let sources: Vec<(String, String, String, Option<String>)> =
                rows.collect::<Result<_, _>>().map_err(be)?;
            for (kind_tag, workspace, folder, last) in sources {
                let Some(kind) = SourceKind::parse(&kind_tag) else { continue };
                let mut chstmt = c
                    .prepare("SELECT channel_name FROM imported_channels WHERE kind = ?1 ORDER BY channel_name")
                    .map_err(be)?;
                let chans: Vec<String> = chstmt
                    .query_map(params![kind_tag], |r| r.get::<_, String>(0))
                    .map_err(be)?
                    .collect::<Result<_, _>>()
                    .map_err(be)?;
                out.push(ConnectedSource {
                    kind,
                    workspace,
                    folder,
                    last_imported_at: last,
                    document_count: chans.len(),
                    imported_channels: chans,
                });
            }
            Ok(out)
        })
        .await
    }

    /// Remove all bookkeeping for a source (its imported Markdown is deleted separately by the
    /// caller). Returns the folder that held it, so the caller can prune files.
    pub async fn remove_source(&self, kind: SourceKind) -> Result<Option<String>, RegistryError> {
        let k = kind.tag().to_string();
        self.with_conn(move |c| {
            let folder: Option<String> = c
                .query_row(
                    "SELECT folder FROM sources WHERE kind = ?1",
                    params![k],
                    |r| r.get::<_, String>(0),
                )
                .ok();
            c.execute("DELETE FROM imported_messages WHERE kind = ?1", params![k])
                .map_err(be)?;
            c.execute("DELETE FROM imported_channels WHERE kind = ?1", params![k])
                .map_err(be)?;
            c.execute("DELETE FROM sources WHERE kind = ?1", params![k])
                .map_err(be)?;
            Ok(folder)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dedup_ledger_makes_reimport_idempotent() {
        let reg = SourceRegistry::open_in_memory().unwrap();
        reg.upsert_source(SourceKind::Slack, "Acme", "Imported/Slack")
            .await
            .unwrap();

        let unseen = reg
            .unseen(SourceKind::Slack, "C1", vec!["m1".into(), "m2".into()])
            .await
            .unwrap();
        assert_eq!(unseen.len(), 2);
        reg.record_import(
            SourceKind::Slack,
            "C1",
            "architecture",
            unseen,
            "2026-01-01T00:00:00Z",
        )
        .await
        .unwrap();

        // Re-import with an overlapping set: only the genuinely new id remains.
        let unseen2 = reg
            .unseen(
                SourceKind::Slack,
                "C1",
                vec!["m1".into(), "m2".into(), "m3".into()],
            )
            .await
            .unwrap();
        assert_eq!(unseen2, vec!["m3".to_string()]);
    }

    #[tokio::test]
    async fn lists_and_removes_sources() {
        let reg = SourceRegistry::open_in_memory().unwrap();
        reg.upsert_source(SourceKind::Slack, "Acme", "Imported/Slack")
            .await
            .unwrap();
        reg.record_import(
            SourceKind::Slack,
            "C1",
            "architecture",
            vec!["m1".into()],
            "2026-01-01T00:00:00Z",
        )
        .await
        .unwrap();

        let sources = reg.list_sources().await.unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].workspace, "Acme");
        assert_eq!(
            sources[0].imported_channels,
            vec!["architecture".to_string()]
        );
        assert_eq!(sources[0].document_count, 1);

        let folder = reg.remove_source(SourceKind::Slack).await.unwrap();
        assert_eq!(folder.as_deref(), Some("Imported/Slack"));
        assert!(reg.list_sources().await.unwrap().is_empty());
    }
}
