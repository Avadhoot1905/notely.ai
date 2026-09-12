//! Model descriptor: which model to run and with what settings, independent of runtime.
//!
//! Mirrors the manifests in `models/manifests/*.yaml`. Weights are NEVER in-repo — a model
//! is identified by name and resolved from a user/cache location at runtime.

use serde::{Deserialize, Serialize};

/// Identifies a model and its key generation settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelDescriptor {
    /// Runtime-facing name/tag, e.g. "qwen3".
    pub name: String,
    /// Maximum context length in tokens, if known.
    pub context_length: Option<u32>,
    /// Quantization tag (e.g. "q4_k_m"), if applicable.
    pub quantization: Option<String>,
}
