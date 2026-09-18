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
use crate::llm::{EmbedRequest, LlmProvider};

use super::chunker::{self, DEFAULT_CHUNK_CHARS};

/// Reciprocal-rank-fusion constant. The standard `k=60`; dampens the influence of any single list so
/// a hit ranked highly by *either* lexical or vector search still surfaces.
const RRF_K: f64 = 60.0;

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
             );
             -- Optional dense-vector side of hybrid search. Populated asynchronously (see
             -- `embed_pending`); empty unless an embedding model is configured. Passage fields are
             -- stored alongside the vector so vector retrieval is self-contained and never has to
             -- re-read the vault at query time.
             CREATE TABLE IF NOT EXISTS embeddings (
                 path       TEXT NOT NULL,
                 chunk_ix   INTEGER NOT NULL,
                 start_line INTEGER NOT NULL,
                 end_line   INTEGER NOT NULL,
                 title      TEXT NOT NULL,
                 body       TEXT NOT NULL,
                 vector     BLOB NOT NULL,
                 PRIMARY KEY (path, chunk_ix)
             );",
        )
        .map_err(be)?;
        // Track which fingerprint has been embedded so re-indexing only re-embeds changed notes.
        // Best-effort ALTER for databases created before this column existed (ignores "duplicate").
        let _ = conn.execute(
            "ALTER TABLE sources ADD COLUMN embedded_fingerprint TEXT",
            [],
        );
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

    /// Hybrid retrieval: lexical FTS5 fused with dense-vector retrieval via reciprocal rank fusion.
    ///
    /// `query_vector` is the caller-computed embedding of `query` (the engine embeds it with the
    /// configured embedding model). When it is `None` — no embedding model configured, the embedder
    /// was unreachable, or nothing has been embedded yet — this degrades to pure FTS5, so search
    /// keeps working exactly as before. Vector-only matches (semantically related, no shared
    /// keyword) still surface; every returned passage remains a real, citable chunk of the vault.
    pub async fn retrieve_hybrid(
        &self,
        query: &str,
        limit: usize,
        query_vector: Option<Vec<f32>>,
    ) -> Result<Vec<Passage>, SearchError> {
        let match_query = to_fts_query(query);
        self.with_conn(move |c| {
            let lexical = if match_query.is_empty() {
                Vec::new()
            } else {
                search_blocking(c, &match_query, limit)?
            };
            let dense = match &query_vector {
                Some(v) if !v.is_empty() => vector_search_blocking(c, v, limit)?,
                _ => Vec::new(),
            };
            if dense.is_empty() {
                return Ok(lexical);
            }
            Ok(fuse_rrf(lexical, dense, limit))
        })
        .await
    }

    /// How many indexed notes still need (re)embedding — their content changed since last embedded.
    pub async fn pending_embedding_count(&self) -> Result<usize, SearchError> {
        self.with_conn(pending_paths_blocking)
            .await
            .map(|p| p.len())
    }

    /// Embed every note whose content changed since it was last embedded, using `embedder`.
    ///
    /// Idempotent and self-healing: "pending" is derived from a fingerprint mismatch in the table,
    /// not from any job record, so an interrupted run simply leaves work pending and the next call
    /// resumes it. A per-note embedding failure is skipped (left pending, hence retryable) rather
    /// than aborting the whole pass. Returns how many notes were successfully embedded.
    pub async fn embed_pending(
        &self,
        embedder: &dyn LlmProvider,
        model: Option<&str>,
    ) -> Result<usize, SearchError> {
        let pending = self.with_conn(pending_paths_blocking).await?;
        let mut embedded = 0usize;
        for path in pending {
            // Read + chunk off the async executor; capture the fingerprint we are about to embed.
            let p = path.clone();
            let prepared = tokio::task::spawn_blocking(move || read_and_chunk(&p))
                .await
                .map_err(|e| SearchError::Backend(e.to_string()))?;
            let Some((fingerprint, chunks)) = prepared else {
                continue; // unreadable/missing: leave for the next sync to prune
            };
            if chunks.is_empty() {
                // Nothing to embed, but mark it done so we don't re-scan it every pass.
                let (pth, fp) = (path.clone(), fingerprint.clone());
                self.with_conn(move |c| store_embeddings_blocking(c, &pth, &fp, &[]))
                    .await?;
                embedded += 1;
                continue;
            }
            let inputs: Vec<String> = chunks.iter().map(|c| c.body.clone()).collect();
            let resp = match embedder
                .embed(EmbedRequest::new(model.map(|m| m.to_string()), inputs))
                .await
            {
                Ok(r) => r,
                // Embedder unreachable/unsupported: stop early, leave everything pending (retryable).
                Err(e) => {
                    tracing::warn!("embedding halted (will retry): {e}");
                    break;
                }
            };
            if resp.vectors.len() != chunks.len() {
                tracing::warn!(
                    "embedding count mismatch for {path} ({} vs {}); skipping",
                    resp.vectors.len(),
                    chunks.len()
                );
                continue;
            }
            let rows: Vec<EmbeddedChunk> = chunks
                .into_iter()
                .zip(resp.vectors)
                .map(|(c, v)| EmbeddedChunk {
                    chunk: c,
                    vector: v,
                })
                .collect();
            let (pth, fp) = (path.clone(), fingerprint.clone());
            self.with_conn(move |c| store_embeddings_blocking(c, &pth, &fp, &rows))
                .await?;
            embedded += 1;
        }
        Ok(embedded)
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
    c.execute("DELETE FROM embeddings WHERE path = ?1", params![path])
        .map_err(be)?;
    c.execute("DELETE FROM sources WHERE path = ?1", params![path])
        .map_err(be)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Dense-vector (embeddings) side of hybrid search.
// ---------------------------------------------------------------------------

/// A chunk's content + provenance, prior to embedding.
struct ChunkData {
    start_line: usize,
    end_line: usize,
    title: String,
    body: String,
}

/// A chunk paired with its embedding vector, ready to store.
struct EmbeddedChunk {
    chunk: ChunkData,
    vector: Vec<f32>,
}

/// Notes whose current fingerprint differs from what was last embedded (or was never embedded).
fn pending_paths_blocking(c: &Connection) -> Result<Vec<String>, SearchError> {
    let mut stmt = c
        .prepare(
            "SELECT path FROM sources
             WHERE embedded_fingerprint IS NULL OR embedded_fingerprint <> fingerprint",
        )
        .map_err(be)?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(be)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(be)?);
    }
    Ok(out)
}

/// Read a note and chunk it (same chunker the FTS index uses), returning its fingerprint so the two
/// stay in lockstep. `None` if the file is gone/unreadable.
fn read_and_chunk(path: &str) -> Option<(String, Vec<ChunkData>)> {
    let p = Path::new(path);
    let fingerprint = fingerprint(p)?;
    let content = std::fs::read_to_string(p).ok()?;
    let title = chunker::first_heading(&content).unwrap_or_else(|| file_stem(path));
    let chunks = chunker::chunk_markdown(&content, DEFAULT_CHUNK_CHARS)
        .into_iter()
        .map(|ch| ChunkData {
            start_line: ch.start_line,
            end_line: ch.end_line,
            title: title.clone(),
            body: ch.text,
        })
        .collect();
    Some((fingerprint, chunks))
}

/// Replace a note's stored embeddings and stamp its `embedded_fingerprint` so it stops being pending.
fn store_embeddings_blocking(
    c: &Connection,
    path: &str,
    fingerprint: &str,
    rows: &[EmbeddedChunk],
) -> Result<(), SearchError> {
    c.execute("DELETE FROM embeddings WHERE path = ?1", params![path])
        .map_err(be)?;
    for (ix, row) in rows.iter().enumerate() {
        c.execute(
            "INSERT INTO embeddings (path, chunk_ix, start_line, end_line, title, body, vector)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                path,
                ix as i64,
                row.chunk.start_line as i64,
                row.chunk.end_line as i64,
                row.chunk.title,
                row.chunk.body,
                encode_vector(&row.vector),
            ],
        )
        .map_err(be)?;
    }
    c.execute(
        "UPDATE sources SET embedded_fingerprint = ?2 WHERE path = ?1",
        params![path, fingerprint],
    )
    .map_err(be)?;
    Ok(())
}

/// Brute-force cosine nearest-neighbor over the stored vectors. For a personal vault (thousands of
/// chunks) a linear scan is more than fast enough and needs no extension/native dependency; if a
/// vault ever outgrows it, this is the single function to swap for an ANN index.
fn vector_search_blocking(
    c: &Connection,
    query: &[f32],
    limit: usize,
) -> Result<Vec<Passage>, SearchError> {
    let mut stmt = c
        .prepare("SELECT path, title, start_line, end_line, body, vector FROM embeddings")
        .map_err(be)?;
    let rows = stmt
        .query_map([], |row| {
            let path: String = row.get(0)?;
            let title: String = row.get(1)?;
            let start_line: i64 = row.get(2)?;
            let end_line: i64 = row.get(3)?;
            let body: String = row.get(4)?;
            let blob: Vec<u8> = row.get(5)?;
            Ok((path, title, start_line, end_line, body, blob))
        })
        .map_err(be)?;

    let mut scored: Vec<(f32, Passage)> = Vec::new();
    for r in rows {
        let (path, title, start_line, end_line, body, blob) = r.map_err(be)?;
        let vector = decode_vector(&blob);
        let score = cosine_similarity(query, &vector);
        if score <= 0.0 {
            continue;
        }
        scored.push((
            score,
            Passage {
                path,
                title,
                start_line: start_line.max(0) as usize,
                end_line: end_line.max(0) as usize,
                body,
            },
        ));
    }
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(limit);
    Ok(scored.into_iter().map(|(_, p)| p).collect())
}

/// Fuse two ranked passage lists with reciprocal rank fusion, keyed by `(path, start_line)` so the
/// same chunk found by both methods is merged (and boosted), not duplicated.
fn fuse_rrf(lexical: Vec<Passage>, dense: Vec<Passage>, limit: usize) -> Vec<Passage> {
    let mut scores: HashMap<(String, usize), f64> = HashMap::new();
    let mut passages: HashMap<(String, usize), Passage> = HashMap::new();
    for list in [lexical, dense] {
        for (rank, passage) in list.into_iter().enumerate() {
            let key = (passage.path.clone(), passage.start_line);
            *scores.entry(key.clone()).or_insert(0.0) += 1.0 / (RRF_K + rank as f64 + 1.0);
            passages.entry(key).or_insert(passage);
        }
    }
    let mut ranked: Vec<((String, usize), f64)> = scores.into_iter().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    ranked.truncate(limit);
    ranked
        .into_iter()
        .filter_map(|(key, _)| passages.remove(&key))
        .collect()
}

/// Encode an `f32` vector as little-endian bytes for BLOB storage.
fn encode_vector(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for f in v {
        out.extend_from_slice(&f.to_le_bytes());
    }
    out
}

/// Decode a little-endian `f32` BLOB back into a vector.
fn decode_vector(bytes: &[u8]) -> Vec<f32> {
    let mut out = Vec::with_capacity(bytes.len() / 4);
    let mut i = 0;
    while i + 4 <= bytes.len() {
        out.push(f32::from_le_bytes([
            bytes[i],
            bytes[i + 1],
            bytes[i + 2],
            bytes[i + 3],
        ]));
        i += 4;
    }
    out
}

/// Cosine similarity; `0.0` for mismatched dimensions or a zero vector (treated as "no signal").
fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
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
    use crate::llm::{EmbedResponse, GenerateRequest, GenerateResponse, LlmError};
    use async_trait::async_trait;

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

    #[test]
    fn vector_encode_decode_roundtrips() {
        let v = vec![0.5f32, -1.0, 3.25, 0.0];
        assert_eq!(decode_vector(&encode_vector(&v)), v);
    }

    #[test]
    fn cosine_handles_mismatch_and_zero() {
        assert_eq!(cosine_similarity(&[1.0, 0.0], &[1.0]), 0.0); // dim mismatch
        assert_eq!(cosine_similarity(&[0.0, 0.0], &[1.0, 1.0]), 0.0); // zero vector
        assert!((cosine_similarity(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn rrf_merges_shared_chunk_and_ranks_it_first() {
        let p = |path: &str, line: usize| Passage {
            path: path.into(),
            title: "t".into(),
            start_line: line,
            end_line: line,
            body: "b".into(),
        };
        // Shared chunk (a.md:0) appears in both lists → should win over singletons.
        let lexical = vec![p("a.md", 0), p("b.md", 0)];
        let dense = vec![p("c.md", 0), p("a.md", 0)];
        let fused = fuse_rrf(lexical, dense, 10);
        assert_eq!((fused[0].path.as_str(), fused[0].start_line), ("a.md", 0));
        assert_eq!(fused.len(), 3, "duplicates merged, not repeated");
    }

    /// A tiny deterministic embedder: 3 dims counting the keywords alpha/beta/gamma. Enough to make
    /// cosine similarity meaningful in a test without a real model.
    struct KeywordEmbedder;
    #[async_trait]
    impl LlmProvider for KeywordEmbedder {
        async fn generate(&self, _r: GenerateRequest) -> Result<GenerateResponse, LlmError> {
            Err(LlmError::Unsupported("generate".into()))
        }
        async fn health(&self) -> Result<(), LlmError> {
            Ok(())
        }
        async fn embed(&self, request: EmbedRequest) -> Result<EmbedResponse, LlmError> {
            let vectors = request
                .input
                .iter()
                .map(|t| {
                    let l = t.to_lowercase();
                    vec![
                        l.matches("alpha").count() as f32,
                        l.matches("beta").count() as f32,
                        l.matches("gamma").count() as f32,
                    ]
                })
                .collect();
            Ok(EmbedResponse {
                vectors,
                model: "keyword".into(),
            })
        }
    }

    fn temp_vault() -> PathBuf {
        // Unique per-call dir under the system temp root (no external tempfile dependency).
        use std::sync::atomic::{AtomicUsize, Ordering};
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let base = std::env::temp_dir().join(format!(
            "notely-search-test-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    #[tokio::test]
    async fn embed_pending_then_hybrid_finds_semantic_match() {
        let vault = temp_vault();
        std::fs::write(vault.join("a.md"), "# Alpha note\nalpha alpha content").unwrap();
        std::fs::write(vault.join("b.md"), "# Beta note\nbeta beta content").unwrap();

        let index = SearchIndex::open_in_memory().unwrap();
        index.sync_vault(vault.clone()).await.unwrap();

        // Both notes are pending until embedded.
        assert_eq!(index.pending_embedding_count().await.unwrap(), 2);
        let n = index.embed_pending(&KeywordEmbedder, None).await.unwrap();
        assert_eq!(n, 2);
        assert_eq!(index.pending_embedding_count().await.unwrap(), 0);

        // Query embedding for "alpha" → should rank the alpha note first even without exact FTS.
        let qvec = KeywordEmbedder
            .embed(EmbedRequest::new(None, vec!["alpha".into()]))
            .await
            .unwrap()
            .vectors
            .remove(0);
        let hits = index.retrieve_hybrid("alpha", 5, Some(qvec)).await.unwrap();
        assert!(!hits.is_empty());
        assert!(hits[0].path.ends_with("a.md"), "alpha note ranked first");

        let _ = std::fs::remove_dir_all(&vault);
    }

    #[tokio::test]
    async fn hybrid_falls_back_to_fts_when_no_vector() {
        let vault = temp_vault();
        std::fs::write(vault.join("a.md"), "# Postgres\nWe use PostgreSQL here.").unwrap();
        let index = SearchIndex::open_in_memory().unwrap();
        index.sync_vault(vault.clone()).await.unwrap();

        // No query vector → pure FTS5, unchanged behavior.
        let hits = index.retrieve_hybrid("postgres", 5, None).await.unwrap();
        assert_eq!(hits.len(), 1);
        assert!(hits[0].body.contains("PostgreSQL"));

        let _ = std::fs::remove_dir_all(&vault);
    }
}
