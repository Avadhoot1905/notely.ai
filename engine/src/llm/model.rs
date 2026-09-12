//! Model descriptor: which model to run, independent of runtime.
//!
//! Mirrors the manifests in `models/manifests/*.yaml`. Weights are NEVER in-repo — a model is
//! identified by name and resolved from the runtime's own store (e.g. Ollama) at runtime.

use serde::{Deserialize, Serialize};

/// The v0 development LLM tag (Qwen3 1.7B). See `models/manifests/qwen3.yaml` and
/// [`crate::config::DEFAULT_LLM_MODEL`].
pub const DEFAULT_MODEL: &str = "qwen3:1.7b";

/// Identifies a model and its key settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelDescriptor {
    /// Runtime-facing name/tag, e.g. "qwen3:4b".
    pub name: String,
    /// Maximum context length in tokens, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_length: Option<u32>,
    /// Quantization tag (e.g. "q4_k_m"), if applicable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quantization: Option<String>,
}

impl Default for ModelDescriptor {
    fn default() -> Self {
        Self {
            name: DEFAULT_MODEL.to_string(),
            context_length: Some(32_768),
            quantization: Some("q4_k_m".to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_model_is_small_qwen() {
        assert_eq!(ModelDescriptor::default().name, "qwen3:1.7b");
    }
}
