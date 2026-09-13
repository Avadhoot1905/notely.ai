//! The vault search index: an FTS5 store over the user's Markdown notes.
//!
//! This is *derived, rebuildable* data — never a source of truth — so it lives in its own SQLite
//! database (`search.db`) separate from the meeting store. The engine reads the same note files
//! the desktop app owns (local-first: both sit on one machine); nothing is copied or locked away.
//!
//! Freshness is kept cheap with incremental sync: each file is fingerprinted by `(mtime, size)`,
//! and only changed/added/removed notes touch the index. Callers can therefore sync before every
//! query without a full re-scan.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

use crate::domain::SearchHit;

use super::chunker::{self, DEFAULT_CHUNK_CHARS};

/// Preview length for search-hit snippets.
const SNIPPET_CHARS: usize = 240;

/// Errors the index can produce.
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("search index backend error: {0}")]
    Backend(String),
}

fn be<E: std::fmt::Display>(e: E) -> SearchError {
    SearchError::Backend(e.to_string())
}

/// What a [`SearchIndex::sync_vault`] pass changed. Useful for logging/tests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SyncStats {
    pub added: usize,
    pub updated: usize,
    pub removed: usize,
    pub unchanged: usize,
}

/// A retrieved passage with its full chunk body — the raw material for answering. The public
/// [`SearchHit`] is derived from this (body trimmed to a snippet) for the search UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Passage {
    pub path: String,
    pub title: String,
    pub start_line: usize,
    pub end_line: usize,
    pub body: String,
}

impl Passage {
    /// The public, UI-facing hit for this passage (body collapsed to a preview).
    pub fn to_hit(&self) -> SearchHit {
        SearchHit {
            path: self.path.clone(),
            title: self.title.clone(),
            start_line: self.start_line,
            end_line: self.end_line,
            snippet: chunker::snippet(&self.body, SNIPPET_CHARS),
        }
    }
}

/// FTS5-backed full-text index over a vault of Markdown notes. Cloneable handle sharing one
/// connection (mirrors `storage::SqliteStore`).
#[derive(Clone)]
pub struct SearchIndex {
    conn: Arc<Mutex<Connection>>,
}

impl SearchIndex {
    /// Open (creating if needed) the index database at `path`.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SearchError> {
        let conn = Connection::open(path).map_err(be)?;
        Self::from_conn(conn)
    }

    /// Open an in-memory index — used by tests.
    pub fn open_in_memory() -> Result<Self, SearchError> {
        let conn = Connection::open_in_memory().map_err(be)?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self, SearchError> {
        conn.execute_batch(
            // unicode61 (no stemming) + prefix queries at search time: intuitive for a notes
            // search, where "postgres" should find "PostgreSQL" and "decis" should find
            // "decision" — a prefix relationship a stemmer would miss.
            "CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
                 path UNINDEXED,
                 title,
                 start_line UNINDEXED,
                 end_line UNINDEXED,
                 body,
                 tokenize = 'unicode61'
             );
             CREATE TABLE IF NOT EXISTS sources (
                 path        TEXT PRIMARY KEY,
                 fingerprint TEXT NOT NULL
             );",
        )
        .map_err(be)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Run a closure with the locked connection on the blocking pool.
    async fn with_conn<T, F>(&self, f: F) -> Result<T, SearchError>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T, SearchError> + Send + 'static,
    {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| SearchError::Backend(e.to_string()))?;
            f(&guard)
        })
        .await
        .map_err(|e| SearchError::Backend(e.to_string()))?
    }

    /// Bring the index in line with the Markdown notes under `root`, touching only what changed.
    pub async fn sync_vault(&self, root: PathBuf) -> Result<SyncStats, SearchError> {
        self.with_conn(move |c| sync_vault_blocking(c, &root)).await
    }

    /// Full-text search for `query`, returning the best-ranked passages first (UI-facing hits).
    pub async fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, SearchError> {
        Ok(self
            .retrieve(query, limit)
            .await?
            .iter()
            .map(Passage::to_hit)
            .collect())
    }

    /// Full-text retrieval returning full passage bodies — the input to answering.
    pub async fn retrieve(&self, query: &str, limit: usize) -> Result<Vec<Passage>, SearchError> {
        let match_query = to_fts_query(query);
        if match_query.is_empty() {
            return Ok(Vec::new());
        }
        self.with_conn(move |c| search_blocking(c, &match_query, limit))
            .await
    }
}

/// Recursively collect Markdown files under `root`, skipping hidden/dot directories.
fn collect_markdown(root: &Path, out: &mut Vec<PathBuf>) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue; // skip .git, .obsidian, and other dot-dirs/files
        }
        let ft = match entry.file_type() {
            Ok(ft) => ft,
            Err(_) => continue,
        };
        if ft.is_dir() {
            collect_markdown(&path, out);
        } else if ft.is_file() && is_markdown(&path) {
            out.push(path);
        }
    }
}

fn is_markdown(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()),
        Some(ref e) if e == "md" || e == "markdown"
    )
}

/// `(mtime_secs, size)` — cheap change detection without hashing file contents.
fn fingerprint(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta
        .modified()
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Some(format!("{modified}:{}", meta.len()))
}

fn sync_vault_blocking(c: &Connection, root: &Path) -> Result<SyncStats, SearchError> {
    let mut files = Vec::new();
    collect_markdown(root, &mut files);
    let present: HashSet<String> = files
        .iter()
        .map(|p| p.to_string_lossy().to_string())
        .collect();

    // Existing fingerprints.
    let mut known: HashMap<String, String> = HashMap::new();
    {
        let mut stmt = c
            .prepare("SELECT path, fingerprint FROM sources")
            .map_err(be)?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(be)?;
        for r in rows {
            let (p, fp) = r.map_err(be)?;
            known.insert(p, fp);
        }
    }

    let mut stats = SyncStats::default();

    for path in &files {
        let key = path.to_string_lossy().to_string();
        let fp = match fingerprint(path) {
            Some(fp) => fp,
            None => continue,
        };
        if known.get(&key).map(|f| f == &fp).unwrap_or(false) {
            stats.unchanged += 1;
            continue;
        }
        let content = match std::fs::read_to_string(path) {
            Ok(s) => s,
            Err(_) => continue, // unreadable/binary: leave any stale rows to be pruned below
        };
        let existed = known.contains_key(&key);
        index_file(c, &key, &content)?;
        upsert_source(c, &key, &fp)?;
        if existed {
            stats.updated += 1;
        } else {
            stats.added += 1;
        }
    }

    // Prune notes that no longer exist.
    let removed: Vec<String> = known
        .keys()
        .filter(|k| !present.contains(*k))
        .cloned()
        .collect();
    for key in removed {
        delete_source(c, &key)?;
        stats.removed += 1;
    }

    Ok(stats)
}

/// Replace all chunk rows for `path` with freshly chunked content.
fn index_file(c: &Connection, path: &str, content: &str) -> Result<(), SearchError> {
    c.execute("DELETE FROM chunks WHERE path = ?1", params![path])
        .map_err(be)?;
    let title = chunker::first_heading(content).unwrap_or_else(|| file_stem(path));
    for chunk in chunker::chunk_markdown(content, DEFAULT_CHUNK_CHARS) {
        c.execute(
            "INSERT INTO chunks (path, title, start_line, end_line, body)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                path,
                title,
                chunk.start_line as i64,
                chunk.end_line as i64,
                chunk.text
            ],
        )
        .map_err(be)?;
    }
    Ok(())
}

fn upsert_source(c: &Connection, path: &str, fingerprint: &str) -> Result<(), SearchError> {
    c.execute(
        "INSERT INTO sources (path, fingerprint) VALUES (?1, ?2)
         ON CONFLICT(path) DO UPDATE SET fingerprint = excluded.fingerprint",
        params![path, fingerprint],
    )
    .map_err(be)?;
    Ok(())
}

fn delete_source(c: &Connection, path: &str) -> Result<(), SearchError> {
    c.execute("DELETE FROM chunks WHERE path = ?1", params![path])
        .map_err(be)?;
    c.execute("DELETE FROM sources WHERE path = ?1", params![path])
        .map_err(be)?;
    Ok(())
}

fn search_blocking(
    c: &Connection,
    match_query: &str,
    limit: usize,
) -> Result<Vec<Passage>, SearchError> {
    let mut stmt = c
        .prepare(
            "SELECT path, title, start_line, end_line, body, bm25(chunks) AS score
             FROM chunks
             WHERE chunks MATCH ?1
             ORDER BY score
             LIMIT ?2",
        )
        .map_err(be)?;
    let rows = stmt
        .query_map(params![match_query, limit as i64], |row| {
            let path: String = row.get(0)?;
            let title: String = row.get(1)?;
            let start_line: i64 = row.get(2)?;
            let end_line: i64 = row.get(3)?;
            let body: String = row.get(4)?;
            Ok(Passage {
                path,
                title,
                start_line: start_line.max(0) as usize,
                end_line: end_line.max(0) as usize,
                body,
            })
        })
        .map_err(be)?;
    let mut passages = Vec::new();
    for r in rows {
        passages.push(r.map_err(be)?);
    }
    Ok(passages)
}

/// The file name without extension — a readable fallback title for a note with no heading.
fn file_stem(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

/// Turn a free-text question into a safe FTS5 MATCH expression: alphanumeric tokens (2+ chars),
/// de-duplicated, each turned into a prefix term (`token*`), OR-joined. Tokens are pure
/// alphanumerics, so they can never contain FTS operator characters — an arbitrary question can
/// never produce a syntax error. Prefix terms give sensible recall ("postgres" → "PostgreSQL").
fn to_fts_query(query: &str) -> String {
    let mut seen = HashSet::new();
    let mut tokens = Vec::new();
    for raw in query.split(|c: char| !c.is_alphanumeric()) {
        let t = raw.trim().to_lowercase();
        if t.len() < 2 {
            continue;
        }
        if seen.insert(t.clone()) {
            tokens.push(format!("{t}*"));
        }
    }
    tokens.join(" OR ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_query_is_sanitized() {
        assert_eq!(
            to_fts_query("postgres migration!"),
            "postgres* OR migration*"
        );
        // Operator-looking input is neutralized (tokens are pure alphanumerics), not a syntax error.
        assert_eq!(to_fts_query("a AND (b OR c)"), "and* OR or*");
        assert_eq!(to_fts_query("  ?? ! "), "");
    }
}
