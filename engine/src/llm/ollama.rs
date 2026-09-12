//! Ollama-backed [`super::LlmProvider`] (the v0 target runtime).
//!
//! TODO(v0): call a local Ollama server's generate endpoint. This file is the ONLY place
//! that should know Ollama exists — the `ai` layer stays runtime-agnostic.

use super::{LlmProvider, LlmRequest, LlmResponse};

/// Talks to a local Ollama instance. Host/config will be added when implemented.
#[derive(Default)]
pub struct OllamaProvider;

impl LlmProvider for OllamaProvider {
    fn generate(&self, _request: &LlmRequest) -> anyhow::Result<LlmResponse> {
        anyhow::bail!("OllamaProvider::generate not implemented")
    }
}
