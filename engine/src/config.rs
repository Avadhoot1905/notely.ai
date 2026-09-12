//! Engine configuration.
//!
//! Loaded from the environment with sensible local-first defaults so nothing machine-specific
//! has to be committed. All knobs live here rather than being scattered as literals across
//! modules. See `docs/development.md` for the documented variables.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Environment variable names (documented in one place).
pub mod env_vars {
    pub const OLLAMA_URL: &str = "NOTELY_OLLAMA_URL";
    pub const OLLAMA_MODEL: &str = "NOTELY_OLLAMA_MODEL";
    pub const OLLAMA_TIMEOUT_SECS: &str = "NOTELY_OLLAMA_TIMEOUT_SECS";
    pub const DATA_DIR: &str = "NOTELY_DATA_DIR";
    pub const LOG_LEVEL: &str = "NOTELY_LOG_LEVEL";
    pub const IPC_ADDR: &str = "NOTELY_IPC_ADDR";
}

/// Configuration for reaching the local Ollama runtime.
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
            // The v0 development model (see models/manifests/qwen3.yaml).
            model: "qwen3:4b".to_string(),
            timeout: Duration::from_secs(120),
        }
    }
}

/// Full engine configuration.
#[derive(Debug, Clone)]
pub struct Config {
    pub ollama: OllamaConfig,
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
            ollama: OllamaConfig::default(),
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
        if let Ok(v) = std::env::var(env_vars::OLLAMA_URL) {
            cfg.ollama.base_url = v;
        }
        if let Ok(v) = std::env::var(env_vars::OLLAMA_MODEL) {
            cfg.ollama.model = v;
        }
        if let Ok(v) = std::env::var(env_vars::OLLAMA_TIMEOUT_SECS) {
            if let Ok(secs) = v.parse::<u64>() {
                cfg.ollama.timeout = Duration::from_secs(secs);
            }
        }
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
