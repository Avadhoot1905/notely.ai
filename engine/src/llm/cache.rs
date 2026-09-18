//! A transparent result cache around any [`LlmProvider`].
//!
//! Generation is deterministic enough for Notely's uses (extraction runs at temperature 0.1) that
//! re-running the exact same request — same model, prompt, schema and parameters — should not pay
//! for inference twice. That happens constantly in practice: reprocessing a meeting, retrying after
//! an LLM blip, or re-answering a repeated question.
//!
//! The cache is a thin wrapper: callers still see an `LlmProvider`, so extraction/synthesis/QA are
//! completely unaware it exists. It is backed by SQLite (its own rebuildable file). Design rules:
//!   - a cache hit skips inference entirely;
//!   - a miss populates the cache **only on success** — a failed generation never poisons it;
//!   - the key covers everything that can change the output (resolved model, system, prompt, schema,
//!     generation parameters, `think`), so a changed prompt/model/input naturally misses;
//!   - every cache error is swallowed (logged) — the wrapper degrades to plain pass-through rather
//!     than ever failing a request.
//!
//! `embed` and `health` pass straight through (embeddings are already de-duplicated upstream by the
//! search index's fingerprints, so caching them here would only duplicate data).

use std::hash::{Hash, Hasher};
use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use rusqlite::{params, Connection, OptionalExtension};

use super::provider::{
    EmbedRequest, EmbedResponse, GenerateRequest, GenerateResponse, LlmError, LlmProvider,
};

/// SQLite-backed store of `(key -> response)` rows. Cloneable handle sharing one connection.
#[derive(Clone)]
pub struct LlmCache {
    conn: Arc<Mutex<Connection>>,
}

impl LlmCache {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, LlmError> {
        let conn = Connection::open(path).map_err(|e| LlmError::Runtime(e.to_string()))?;
        Self::from_conn(conn)
    }

    pub fn open_in_memory() -> Result<Self, LlmError> {
        let conn = Connection::open_in_memory().map_err(|e| LlmError::Runtime(e.to_string()))?;
        Self::from_conn(conn)
    }

    fn from_conn(conn: Connection) -> Result<Self, LlmError> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS llm_cache (
                 key        TEXT PRIMARY KEY,
                 model      TEXT NOT NULL,
                 response   TEXT NOT NULL,
                 created_at TEXT NOT NULL
             );",
        )
        .map_err(|e| LlmError::Runtime(e.to_string()))?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    fn get(&self, key: &str) -> Option<(String, String)> {
        let guard = self.conn.lock().ok()?;
        guard
            .query_row(
                "SELECT response, model FROM llm_cache WHERE key = ?1",
                params![key],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .ok()
            .flatten()
    }

    fn put(&self, key: &str, model: &str, response: &str, now: &str) {
        let Ok(guard) = self.conn.lock() else { return };
        let _ = guard.execute(
            "INSERT INTO llm_cache (key, model, response, created_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(key) DO UPDATE SET response = excluded.response, model = excluded.model,
                                            created_at = excluded.created_at",
            params![key, model, response, now],
        );
    }

    /// Number of cached rows (test/introspection helper).
    pub fn len(&self) -> usize {
        self.conn
            .lock()
            .ok()
            .and_then(|c| {
                c.query_row("SELECT COUNT(*) FROM llm_cache", [], |r| r.get::<_, i64>(0))
                    .ok()
            })
            .unwrap_or(0) as usize
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Wraps an inner provider, serving generations from [`LlmCache`] when possible.
pub struct CachingLlmProvider {
    inner: Arc<dyn LlmProvider>,
    cache: LlmCache,
    /// The inner runtime's default model, used to resolve `None` into the concrete model for the
    /// cache key so that changing the default model invalidates old entries.
    default_model: String,
}

impl CachingLlmProvider {
    pub fn new(inner: Arc<dyn LlmProvider>, cache: LlmCache, default_model: String) -> Self {
        Self {
            inner,
            cache,
            default_model,
        }
    }
}

/// Deterministic cache key covering every input that can change the output.
pub fn cache_key(default_model: &str, request: &GenerateRequest) -> String {
    let model = request.model.as_deref().unwrap_or(default_model);
    let format = request
        .format
        .as_ref()
        .map(|v| v.to_string())
        .unwrap_or_default();
    // A single canonical, unambiguously-delimited string, then hashed.
    let canonical = format!(
        "v1\u{1f}{model}\u{1f}{system}\u{1f}{prompt}\u{1f}{format}\u{1f}{temp:?}\u{1f}{ctx:?}\u{1f}{max:?}\u{1f}{think}",
        system = request.system.as_deref().unwrap_or(""),
        prompt = request.prompt,
        temp = request.config.temperature,
        ctx = request.config.num_ctx,
        max = request.config.max_tokens,
        think = request.think,
    );
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    canonical.hash(&mut hasher);
    let h1 = hasher.finish();
    // Mix a second pass with a length salt to shrink collision odds for a local cache.
    canonical.len().hash(&mut hasher);
    let h2 = hasher.finish();
    format!("{model}:{h1:016x}{h2:016x}")
}

#[async_trait]
impl LlmProvider for CachingLlmProvider {
    async fn generate(&self, request: GenerateRequest) -> Result<GenerateResponse, LlmError> {
        let key = cache_key(&self.default_model, &request);
        if let Some((text, model)) = self.cache.get(&key) {
            return Ok(GenerateResponse { text, model });
        }
        let response = self.inner.generate(request).await?; // errors never touch the cache
        let now = chrono::Utc::now().to_rfc3339();
        self.cache.put(&key, &response.model, &response.text, &now);
        Ok(response)
    }

    async fn health(&self) -> Result<(), LlmError> {
        self.inner.health().await
    }

    async fn embed(&self, request: EmbedRequest) -> Result<EmbedResponse, LlmError> {
        self.inner.embed(request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{GenerateResponse, LlmError};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Counts how many times the inner provider is actually hit.
    struct CountingLlm {
        calls: AtomicUsize,
    }
    #[async_trait]
    impl LlmProvider for CountingLlm {
        async fn generate(&self, _r: GenerateRequest) -> Result<GenerateResponse, LlmError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(GenerateResponse {
                text: "hello".into(),
                model: "test".into(),
            })
        }
        async fn health(&self) -> Result<(), LlmError> {
            Ok(())
        }
    }

    /// Always fails — used to prove failures never populate the cache.
    struct FailingLlm;
    #[async_trait]
    impl LlmProvider for FailingLlm {
        async fn generate(&self, _r: GenerateRequest) -> Result<GenerateResponse, LlmError> {
            Err(LlmError::Transport("down".into()))
        }
        async fn health(&self) -> Result<(), LlmError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn hit_bypasses_inference_miss_populates() {
        let inner = Arc::new(CountingLlm {
            calls: AtomicUsize::new(0),
        });
        let cache = LlmCache::open_in_memory().unwrap();
        let provider = CachingLlmProvider::new(inner.clone(), cache.clone(), "test".into());

        let r1 = provider.generate(GenerateRequest::new("hi")).await.unwrap();
        assert_eq!(r1.text, "hello");
        assert_eq!(inner.calls.load(Ordering::SeqCst), 1);
        assert_eq!(cache.len(), 1);

        // Identical request → served from cache, inner not called again.
        let r2 = provider.generate(GenerateRequest::new("hi")).await.unwrap();
        assert_eq!(r2.text, "hello");
        assert_eq!(
            inner.calls.load(Ordering::SeqCst),
            1,
            "should be a cache hit"
        );
    }

    #[tokio::test]
    async fn changed_input_or_model_invalidates() {
        let inner = Arc::new(CountingLlm {
            calls: AtomicUsize::new(0),
        });
        let cache = LlmCache::open_in_memory().unwrap();
        let provider = CachingLlmProvider::new(inner.clone(), cache, "test".into());

        provider.generate(GenerateRequest::new("a")).await.unwrap();
        provider.generate(GenerateRequest::new("b")).await.unwrap(); // different prompt
        let mut with_model = GenerateRequest::new("a");
        with_model.model = Some("other".into());
        provider.generate(with_model).await.unwrap(); // different model
        assert_eq!(inner.calls.load(Ordering::SeqCst), 3, "all distinct keys");
    }

    #[tokio::test]
    async fn failed_inference_does_not_poison_cache() {
        let cache = LlmCache::open_in_memory().unwrap();
        let provider = CachingLlmProvider::new(Arc::new(FailingLlm), cache.clone(), "test".into());
        assert!(provider.generate(GenerateRequest::new("hi")).await.is_err());
        assert!(cache.is_empty(), "a failure must not be cached");
    }

    #[test]
    fn key_is_stable_and_distinguishes_params() {
        let a = cache_key("m", &GenerateRequest::new("x"));
        let b = cache_key("m", &GenerateRequest::new("x"));
        assert_eq!(a, b);
        let c = cache_key("m", &GenerateRequest::new("x").with_temperature(0.9));
        assert_ne!(a, c);
    }
}
