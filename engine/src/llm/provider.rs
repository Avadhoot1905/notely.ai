//! The runtime-agnostic LLM abstraction.
//!
//! This exposes only the capabilities Notely actually needs — not the whole Ollama API. The
//! `ai` layer depends on [`LlmProvider`]; it never knows which runtime serves the model.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Generation knobs. Kept small; extend only when a real need appears.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GenerationConfig {
    /// Sampling temperature. Low values (~0.2) suit structured extraction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    /// Context window to request from the runtime, if it should differ from the model default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_ctx: Option<u32>,
    /// Cap on generated tokens, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
}

/// A single generation request.
#[derive(Debug, Clone)]
pub struct GenerateRequest {
    /// Model tag. `None` => the provider's configured default model.
    pub model: Option<String>,
    /// System prompt (role/instructions).
    pub system: Option<String>,
    /// User/context prompt.
    pub prompt: String,
    /// When set, a JSON Schema the runtime must constrain output to (structured output).
    pub format: Option<Value>,
    pub config: GenerationConfig,
    /// Whether to allow model "thinking" tokens. Off by default for structured output.
    pub think: bool,
}

impl GenerateRequest {
    /// A plain prompt with default settings.
    pub fn new(prompt: impl Into<String>) -> Self {
        Self {
            model: None,
            system: None,
            prompt: prompt.into(),
            format: None,
            config: GenerationConfig::default(),
            think: false,
        }
    }

    pub fn with_system(mut self, system: impl Into<String>) -> Self {
        self.system = Some(system.into());
        self
    }

    /// Constrain output to the given JSON Schema (structured output).
    pub fn with_format(mut self, schema: Value) -> Self {
        self.format = Some(schema);
        self
    }

    pub fn with_temperature(mut self, temperature: f32) -> Self {
        self.config.temperature = Some(temperature);
        self
    }
}

/// The generated result.
#[derive(Debug, Clone)]
pub struct GenerateResponse {
    pub text: String,
    pub model: String,
}

/// A request to embed one or more texts. Batch by construction: a single call embeds every input,
/// which is what re-indexing a note (many chunks) needs and what runtimes like Ollama accept
/// natively. A single text is just a one-element batch.
#[derive(Debug, Clone)]
pub struct EmbedRequest {
    /// Embedding model tag. `None` => the provider's configured default model. Embeddings usually
    /// need a *dedicated* embedding model, so callers normally set this explicitly.
    pub model: Option<String>,
    /// The texts to embed, in order. The response vectors correspond 1:1.
    pub input: Vec<String>,
}

impl EmbedRequest {
    /// Embed a batch of texts with the given model.
    pub fn new(model: Option<String>, input: Vec<String>) -> Self {
        Self { model, input }
    }
}

/// The embedding result: one vector per input, in the same order.
#[derive(Debug, Clone)]
pub struct EmbedResponse {
    pub vectors: Vec<Vec<f32>>,
    pub model: String,
}

/// Errors a provider can produce.
#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("failed to reach the LLM runtime: {0}")]
    Transport(String),
    #[error("the LLM runtime returned an error: {0}")]
    Runtime(String),
    #[error("could not decode the LLM runtime response: {0}")]
    Decode(String),
    /// The runtime does not implement a requested capability (e.g. a chat-only backend asked to
    /// embed). Callers treat this as "feature unavailable" and degrade, never as a hard failure.
    #[error("the LLM runtime does not support this capability: {0}")]
    Unsupported(String),
}

/// Executes generation against some local (later, possibly remote) runtime.
#[async_trait]
pub trait LlmProvider: Send + Sync {
    /// Run a single generation.
    async fn generate(&self, request: GenerateRequest) -> Result<GenerateResponse, LlmError>;

    /// Cheap liveness/reachability check against the runtime.
    async fn health(&self) -> Result<(), LlmError>;

    /// Produce embeddings for a batch of texts.
    ///
    /// Defaulted to `Unsupported` so a provider only opts in when its runtime actually embeds
    /// (Ollama does; a plain chat runtime may not). Embeddings power hybrid search, which stays
    /// entirely optional — callers fall back to FTS5 when this returns `Unsupported`.
    async fn embed(&self, request: EmbedRequest) -> Result<EmbedResponse, LlmError> {
        let _ = request;
        Err(LlmError::Unsupported("embeddings".into()))
    }
}
