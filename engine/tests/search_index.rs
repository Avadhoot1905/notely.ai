//! Integration coverage for vault retrieval over real files on disk: the FTS5 index's incremental
//! sync (add / update / remove) and full-text search, plus the end-to-end Ask path degrading
//! gracefully when no LLM runtime is reachable.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use notely_engine::config::Config;
use notely_engine::ipc::protocol::{Request, Response};
use notely_engine::search::SearchIndex;
use notely_engine::Engine;

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A unique, self-cleaning temp directory for a test's vault/data.
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("notely-{tag}-{nanos}-{n}"));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }

    fn write(&self, name: &str, content: &str) -> PathBuf {
        let p = self.0.join(name);
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&p, content).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[tokio::test]
async fn syncs_searches_and_tracks_line_ranges() {
    let vault = TempDir::new("vault");
    vault.write(
        "arch.md",
        "# Architecture\n\nWe decided to use PostgreSQL for the database migration.\n",
    );
    vault.write("misc.md", "# Misc\n\nUnrelated grocery list.\n");
    // A dot-directory must be ignored entirely.
    vault.write(
        ".git/config.md",
        "# secret\n\nPostgreSQL internals not to be indexed.\n",
    );

    let index = SearchIndex::open_in_memory().unwrap();
    let stats = index.sync_vault(vault.path().to_path_buf()).await.unwrap();
    assert_eq!(stats.added, 2, "two real notes indexed, dot-dir skipped");

    let hits = index.search("postgres migration", 10).await.unwrap();
    assert!(!hits.is_empty());
    let top = &hits[0];
    assert!(
        top.path.ends_with("arch.md"),
        "best hit is the architecture note"
    );
    assert_eq!(top.title, "Architecture");
    assert!(top.snippet.to_lowercase().contains("postgresql"));
    // A short note (heading + a paragraph) is one passage; its range starts at line 0 and spans
    // the body, so highlight-on-click covers the whole note.
    assert_eq!(top.start_line, 0);
    assert!(top.end_line >= 2);
    // The ignored dot-dir file never surfaces.
    assert!(hits.iter().all(|h| !h.path.contains(".git")));
}

#[tokio::test]
async fn reindexes_changed_and_prunes_removed_notes() {
    let vault = TempDir::new("vault");
    let note = vault.write("topic.md", "# Topic\n\nRedis caching notes.\n");
    let index = SearchIndex::open_in_memory().unwrap();
    index.sync_vault(vault.path().to_path_buf()).await.unwrap();

    assert!(!index.search("redis", 10).await.unwrap().is_empty());
    assert!(index.search("postgres", 10).await.unwrap().is_empty());

    // Rewrite with different content (and length, so the fingerprint changes regardless of
    // filesystem mtime resolution).
    std::fs::write(
        &note,
        "# Topic\n\nSwitched the caching discussion to PostgreSQL entirely.\n",
    )
    .unwrap();
    let stats = index.sync_vault(vault.path().to_path_buf()).await.unwrap();
    assert_eq!(stats.updated, 1);
    assert!(!index.search("postgres", 10).await.unwrap().is_empty());
    assert!(
        index.search("redis", 10).await.unwrap().is_empty(),
        "old content pruned"
    );

    // Remove the note entirely.
    std::fs::remove_file(&note).unwrap();
    let stats = index.sync_vault(vault.path().to_path_buf()).await.unwrap();
    assert_eq!(stats.removed, 1);
    assert!(index.search("postgres", 10).await.unwrap().is_empty());
}

#[tokio::test]
async fn unchanged_notes_are_not_reindexed() {
    let vault = TempDir::new("vault");
    vault.write("a.md", "# A\n\nStable content.\n");
    let index = SearchIndex::open_in_memory().unwrap();
    let first = index.sync_vault(vault.path().to_path_buf()).await.unwrap();
    assert_eq!(first.added, 1);
    let second = index.sync_vault(vault.path().to_path_buf()).await.unwrap();
    assert_eq!(second.unchanged, 1);
    assert_eq!(second.added, 0);
    assert_eq!(second.updated, 0);
}

/// End-to-end via the engine: Ask returns a grounded, cited answer even with no LLM runtime
/// running — it degrades to a deterministic source list rather than failing.
#[tokio::test]
async fn engine_ask_is_grounded_and_degrades_without_llm() {
    let vault = TempDir::new("vault");
    vault.write(
        "decision.md",
        "# Database Decision\n\nWe chose PostgreSQL for Project X after evaluating alternatives.\n",
    );
    let data = TempDir::new("data");
    let config = Config {
        data_dir: data.path().to_path_buf(),
        ..Default::default()
    };
    let engine = Engine::new(config).expect("engine builds");

    // Search returns the note.
    let resp = engine
        .dispatch(Request::Search {
            query: "PostgreSQL decision".into(),
            vault_path: vault.path().to_string_lossy().to_string(),
            limit: None,
        })
        .await;
    match resp {
        Response::SearchResults(hits) => {
            assert!(hits.iter().any(|h| h.path.ends_with("decision.md")));
        }
        other => panic!("expected SearchResults, got {other:?}"),
    }

    // Ask grounds the answer in that note and cites it, even though Ollama is not running here.
    let resp = engine
        .dispatch(Request::Ask {
            question: "What database did we choose for Project X?".into(),
            vault_path: vault.path().to_string_lossy().to_string(),
        })
        .await;
    match resp {
        Response::Answer(answer) => {
            assert!(
                !answer.citations.is_empty(),
                "answer is grounded in sources"
            );
            assert!(answer.citations[0].path.ends_with("decision.md"));
            assert!(!answer.files_read.is_empty());
            assert!(!answer.text.is_empty());
        }
        other => panic!("expected Answer, got {other:?}"),
    }
}
