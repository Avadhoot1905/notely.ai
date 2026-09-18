//! Engine configuration.
//!
//! Loaded from the environment with sensible local-first defaults so nothing machine-specific has
//! to be committed. All knobs live here rather than being scattered as literals across modules.
//!
//! Notely uses **two separate runtimes** (see `docs/ai-engine.md`):
//!   - the **LLM** (meeting understanding) served by **Ollama** — default `qwen3:1.7b`;
//!   - **ASR** (speech recognition) served by a **separate Qwen3-ASR runtime** — *not* Ollama.
//!
//! See `docs/development.md` for the documented variables.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Environment variable names (documented in one place).
pub mod env_vars {
    // LLM runtime selection. `ollama` (default, cross-platform) | `mlx` (Apple Silicon).
    pub const LLM_PROVIDER: &str = "NOTELY_LLM_PROVIDER";

    // LLM (Ollama).
    pub const OLLAMA_URL: &str = "NOTELY_OLLAMA_URL";
    /// Preferred name for the LLM model tag.
    pub const LLM_MODEL: &str = "NOTELY_LLM_MODEL";
    /// Legacy alias for [`LLM_MODEL`], still honored.
    pub const OLLAMA_MODEL: &str = "NOTELY_OLLAMA_MODEL";
    pub const OLLAMA_TIMEOUT_SECS: &str = "NOTELY_OLLAMA_TIMEOUT_SECS";

    // MLX (optional Apple-Silicon runtime; an external MLX-LM HTTP server).
    pub const MLX_URL: &str = "NOTELY_MLX_URL";
    pub const MLX_MODEL: &str = "NOTELY_MLX_MODEL";
    pub const MLX_TIMEOUT_SECS: &str = "NOTELY_MLX_TIMEOUT_SECS";

    // Optional per-task model routing. Each falls back to the runtime's default model when unset.
    pub const LLM_MODEL_EXTRACTION: &str = "NOTELY_LLM_MODEL_EXTRACTION";
    pub const LLM_MODEL_SYNTHESIS: &str = "NOTELY_LLM_MODEL_SYNTHESIS";
    pub const LLM_MODEL_QA: &str = "NOTELY_LLM_MODEL_QA";
    /// Setting this turns on embeddings/hybrid search. Unset => FTS5-only (unchanged behavior).
    pub const LLM_MODEL_EMBEDDING: &str = "NOTELY_LLM_MODEL_EMBEDDING";

    // ASR (separate runtime).
    pub const ASR_PROVIDER: &str = "NOTELY_ASR_PROVIDER";
    pub const ASR_URL: &str = "NOTELY_ASR_URL";
    pub const ASR_MODEL: &str = "NOTELY_ASR_MODEL";
    pub const ASR_TIMEOUT_SECS: &str = "NOTELY_ASR_TIMEOUT_SECS";

    // Engine.
    pub const DATA_DIR: &str = "NOTELY_DATA_DIR";
    pub const LOG_LEVEL: &str = "NOTELY_LOG_LEVEL";
    pub const IPC_ADDR: &str = "NOTELY_IPC_ADDR";
}

/// Which LLM runtime the engine talks to. All are reached through the same `LlmProvider` boundary,
/// so the rest of the engine is identical regardless of choice. A future GPU runtime (e.g. vLLM)
/// would slot in here as another variant without touching the pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LlmProviderKind {
    /// Ollama (default). Cross-platform; uses CUDA automatically on NVIDIA, Metal on macOS, CPU otherwise.
    Ollama,
    /// MLX-LM served by a separate local HTTP server (Apple Silicon). Opt-in.
    Mlx,
}

impl LlmProviderKind {
    fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "ollama" => Some(Self::Ollama),
            "mlx" | "mlx-lm" | "mlx_lm" => Some(Self::Mlx),
            _ => None,
        }
    }
}

/// Configuration for reaching an external MLX-LM HTTP server (OpenAI-compatible API).
#[derive(Debug, Clone)]
pub struct MlxConfig {
    pub base_url: String,
    pub model: String,
    pub timeout: Duration,
}

impl Default for MlxConfig {
    fn default() -> Self {
        Self {
            // `mlx_lm.server` default port.
            base_url: "http://localhost:8080".to_string(),
            model: DEFAULT_LLM_MODEL.to_string(),
            timeout: Duration::from_secs(180),
        }
    }
}

/// Optional per-task model overrides. `None` preserves the current default-model behavior for that
/// task. `embedding` doubles as the on/off switch for hybrid search.
#[derive(Debug, Clone, Default)]
pub struct ModelRoutes {
    pub extraction: Option<String>,
    pub synthesis: Option<String>,
    pub qa: Option<String>,
    pub embedding: Option<String>,
}

/// The default LLM model tag (Qwen3 1.7B). Small enough for a dev laptop; configurable so 0.6B/4B
/// can be benchmarked later without changing the pipeline.
pub const DEFAULT_LLM_MODEL: &str = "qwen3:1.7b";

/// Configuration for reaching the local Ollama runtime (the LLM / meeting-understanding model).
#[derive(Debug, Clone)]
pub struct OllamaConfig {
    pub base_url: String,
    pub model: String,
    pub timeout: Duration,
}

impl Default for OllamaConfig {
    fn default() -> Self {
        Self {
            base_url: "http://localhost:11434".to_string(),
            model: DEFAULT_LLM_MODEL.to_string(),
            timeout: Duration::from_secs(180),
        }
    }
}

/// Which ASR provider the engine uses. ASR is deliberately independent of the LLM runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsrProviderKind {
    /// Qwen3-ASR served by a separate ASR runtime over HTTP (the v0 default).
    Qwen3Asr,
    /// Whisper (optional/future).
    Whisper,
    /// Deterministic fixture provider (tests / offline dev).
    Fixture,
}

impl AsrProviderKind {
    fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "qwen3-asr" | "qwen3_asr" | "qwen" => Some(Self::Qwen3Asr),
            "whisper" => Some(Self::Whisper),
            "fixture" | "mock" => Some(Self::Fixture),
            _ => None,
        }
    }
}

/// Configuration for the ASR runtime. This is a **separate** HTTP runtime from Ollama.
#[derive(Debug, Clone)]
pub struct AsrConfig {
    pub provider: AsrProviderKind,
    /// Base URL of the Qwen3-ASR runtime (e.g. a local Python inference server).
    pub base_url: String,
    /// Model identifier understood by that runtime.
    pub model: String,
    /// Transcription can be slow; allow a generous timeout.
    pub timeout: Duration,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            provider: AsrProviderKind::Qwen3Asr,
            base_url: "http://localhost:9000".to_string(),
            model: "qwen3-asr".to_string(),
            timeout: Duration::from_secs(600),
        }
    }
}

/// Deterministic transcript chunking parameters (see `engine/src/preprocess`).
#[derive(Debug, Clone)]
pub struct ChunkingConfig {
    /// Approximate maximum characters of transcript text per chunk (a proxy for token budget).
    pub max_chars: usize,
    /// Characters of neighboring context attached to each chunk (overlap for continuity).
    pub context_chars: usize,
}

impl Default for ChunkingConfig {
    fn default() -> Self {
        // ~1.5k tokens of primary text per chunk keeps small models (1.7B) well within context.
        Self {
            max_chars: 6_000,
            context_chars: 400,
        }
    }
}

/// Full engine configuration.
#[derive(Debug, Clone)]
pub struct Config {
    /// Which LLM runtime to use (Ollama by default).
    pub llm_provider: LlmProviderKind,
    pub ollama: OllamaConfig,
    pub mlx: MlxConfig,
    /// Optional per-task model routing (extraction/synthesis/qa/embedding).
    pub models: ModelRoutes,
    pub asr: AsrConfig,
    pub chunking: ChunkingConfig,
    /// Directory for the local database and generated artifacts (outside the repo).
    pub data_dir: PathBuf,
    /// `tracing` filter, e.g. "info" or "notely_engine=debug".
    pub log_level: String,
    /// Loopback address the IPC server binds to.
    pub ipc_addr: SocketAddr,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            llm_provider: LlmProviderKind::Ollama,
            ollama: OllamaConfig::default(),
            mlx: MlxConfig::default(),
            models: ModelRoutes::default(),
            asr: AsrConfig::default(),
            chunking: ChunkingConfig::default(),
            data_dir: default_data_dir(),
            log_level: "info".to_string(),
            ipc_addr: "127.0.0.1:8765".parse().expect("valid default addr"),
        }
    }
}

impl Config {
    /// Build configuration from environment variables, falling back to defaults.
    pub fn from_env() -> Self {
        let mut cfg = Config::default();

        // LLM runtime selection.
        if let Ok(v) = std::env::var(env_vars::LLM_PROVIDER) {
            if let Some(kind) = LlmProviderKind::parse(&v) {
                cfg.llm_provider = kind;
            }
        }

        // LLM (Ollama).
        if let Ok(v) = std::env::var(env_vars::OLLAMA_URL) {
            cfg.ollama.base_url = v;
        }
        // Preferred NOTELY_LLM_MODEL, falling back to the legacy NOTELY_OLLAMA_MODEL. Also seeds the
        // MLX default model so a single knob works regardless of the selected runtime.
        if let Ok(v) =
            std::env::var(env_vars::LLM_MODEL).or_else(|_| std::env::var(env_vars::OLLAMA_MODEL))
        {
            cfg.ollama.model = v.clone();
            cfg.mlx.model = v;
        }
        if let Some(d) = env_secs(env_vars::OLLAMA_TIMEOUT_SECS) {
            cfg.ollama.timeout = d;
        }

        // MLX (optional Apple-Silicon runtime).
        if let Ok(v) = std::env::var(env_vars::MLX_URL) {
            cfg.mlx.base_url = v;
        }
        if let Ok(v) = std::env::var(env_vars::MLX_MODEL) {
            cfg.mlx.model = v;
        }
        if let Some(d) = env_secs(env_vars::MLX_TIMEOUT_SECS) {
            cfg.mlx.timeout = d;
        }

        // Per-task model routing (all optional; unset preserves default-model behavior).
        cfg.models.extraction = std::env::var(env_vars::LLM_MODEL_EXTRACTION).ok();
        cfg.models.synthesis = std::env::var(env_vars::LLM_MODEL_SYNTHESIS).ok();
        cfg.models.qa = std::env::var(env_vars::LLM_MODEL_QA).ok();
        cfg.models.embedding = std::env::var(env_vars::LLM_MODEL_EMBEDDING).ok();

        // ASR (separate runtime).
        if let Ok(v) = std::env::var(env_vars::ASR_PROVIDER) {
            if let Some(kind) = AsrProviderKind::parse(&v) {
                cfg.asr.provider = kind;
            }
        }
        if let Ok(v) = std::env::var(env_vars::ASR_URL) {
            cfg.asr.base_url = v;
        }
        if let Ok(v) = std::env::var(env_vars::ASR_MODEL) {
            cfg.asr.model = v;
        }
        if let Some(d) = env_secs(env_vars::ASR_TIMEOUT_SECS) {
            cfg.asr.timeout = d;
        }

        // Engine.
        if let Ok(v) = std::env::var(env_vars::DATA_DIR) {
            cfg.data_dir = PathBuf::from(v);
        }
        if let Ok(v) = std::env::var(env_vars::LOG_LEVEL) {
            cfg.log_level = v;
        }
        if let Ok(v) = std::env::var(env_vars::IPC_ADDR) {
            if let Ok(addr) = v.parse() {
                cfg.ipc_addr = addr;
            }
        }
        cfg
    }

    /// Path to the SQLite database file within the data dir.
    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join("notely.db")
    }

    /// Path to the derived full-text search index. Kept separate from the meeting store because it
    /// is rebuildable data (losing it costs only a re-sync), not a source of truth.
    pub fn search_index_path(&self) -> PathBuf {
        self.data_dir.join("search.db")
    }

    /// Path to the persistent job queue. Operational metadata; kept separate from the meeting store.
    pub fn jobs_path(&self) -> PathBuf {
        self.data_dir.join("jobs.db")
    }

    /// Path to the LLM result cache. Purely a speed-up; rebuildable, so it lives on its own.
    pub fn llm_cache_path(&self) -> PathBuf {
        self.data_dir.join("llm_cache.db")
    }

    /// The default model tag of the currently selected LLM runtime.
    pub fn active_model(&self) -> &str {
        match self.llm_provider {
            LlmProviderKind::Ollama => &self.ollama.model,
            LlmProviderKind::Mlx => &self.mlx.model,
        }
    }
}

fn env_secs(name: &str) -> Option<Duration> {
    std::env::var(name)
        .ok()?
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
}

/// OS-appropriate application data directory (outside the repository working tree).
fn default_data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("HOME") {
        #[cfg(target_os = "macos")]
        {
            return PathBuf::from(dir)
                .join("Library")
                .join("Application Support")
                .join("ai.notely");
        }
        #[cfg(not(target_os = "macos"))]
        {
            return PathBuf::from(dir)
                .join(".local")
                .join("share")
                .join("notely");
        }
    }
    PathBuf::from(".notely-data")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_use_small_qwen_and_separate_asr() {
        let cfg = Config::default();
        assert_eq!(cfg.ollama.model, "qwen3:1.7b");
        assert_eq!(cfg.asr.provider, AsrProviderKind::Qwen3Asr);
        // ASR runtime is NOT the Ollama runtime.
        assert_ne!(cfg.asr.base_url, cfg.ollama.base_url);
    }

    #[test]
    fn parses_llm_provider_kinds_and_defaults_to_ollama() {
        assert_eq!(Config::default().llm_provider, LlmProviderKind::Ollama);
        assert_eq!(
            LlmProviderKind::parse("ollama"),
            Some(LlmProviderKind::Ollama)
        );
        assert_eq!(LlmProviderKind::parse("MLX"), Some(LlmProviderKind::Mlx));
        assert_eq!(LlmProviderKind::parse("mlx-lm"), Some(LlmProviderKind::Mlx));
        assert_eq!(LlmProviderKind::parse("nope"), None);
    }

    #[test]
    fn active_model_follows_selected_runtime() {
        let mut cfg = Config {
            ollama: OllamaConfig {
                model: "qwen3:1.7b".into(),
                ..OllamaConfig::default()
            },
            mlx: MlxConfig {
                model: "qwen3-mlx".into(),
                ..MlxConfig::default()
            },
            ..Config::default()
        };
        assert_eq!(cfg.active_model(), "qwen3:1.7b");
        cfg.llm_provider = LlmProviderKind::Mlx;
        assert_eq!(cfg.active_model(), "qwen3-mlx");
    }

    #[test]
    fn model_routes_default_to_none() {
        // Unset routing preserves default-model behavior for every task.
        let routes = ModelRoutes::default();
        assert!(routes.extraction.is_none());
        assert!(routes.synthesis.is_none());
        assert!(routes.qa.is_none());
        assert!(routes.embedding.is_none());
    }

    #[test]
    fn parses_asr_provider_kinds() {
        assert_eq!(
            AsrProviderKind::parse("qwen3-asr"),
            Some(AsrProviderKind::Qwen3Asr)
        );
        assert_eq!(
            AsrProviderKind::parse("Whisper"),
            Some(AsrProviderKind::Whisper)
        );
        assert_eq!(
            AsrProviderKind::parse("fixture"),
            Some(AsrProviderKind::Fixture)
        );
        assert_eq!(AsrProviderKind::parse("nope"), None);
    }
}
