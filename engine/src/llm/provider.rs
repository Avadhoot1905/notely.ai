//! The runtime-agnostic LLM abstraction.

use serde::{Deserialize, Serialize};

/// A single generation request. Kept minimal for v0.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmRequest {
    /// Model name/id as understood by the runtime (see [`super::model`]).
    pub model: String,
    pub prompt: String,
    /// Optional system prompt for role/instructions.
    pub system: Option<String>,
}

/// The generated result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmResponse {
    pub text: String,
}

/// Executes generation against some local (or remote, later) runtime.
///
/// Implementations own transport and runtime specifics. Callers in `ai` depend only on this.
pub trait LlmProvider {
    /// TODO(v0): make async and add streaming once the transport is chosen.
    fn generate(&self, request: &LlmRequest) -> anyhow::Result<LlmResponse>;
}
