//! LLM runtime / provider layer.
//!
//! Owns *how* an LLM is executed. The [`crate::ai`] layer asks for semantic operations through
//! [`LlmProvider`]; it must not know whether inference happens via Ollama, llama.cpp, or anything
//! else. Ollama is the v0 target. `provider` (the abstraction) and `model` (which model) are kept
//! separate so a model can be re-pointed at a different runtime without changing callers.

pub mod model;
pub mod ollama;
pub mod provider;

pub use model::{ModelDescriptor, DEFAULT_MODEL};
pub use ollama::OllamaProvider;
pub use provider::{GenerateRequest, GenerateResponse, GenerationConfig, LlmError, LlmProvider};
