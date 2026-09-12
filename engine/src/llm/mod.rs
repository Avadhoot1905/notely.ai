//! LLM runtime / provider layer.
//!
//! This module owns *how* an LLM is executed. The [`ai`](crate::ai) layer asks for semantic
//! operations through [`provider::LlmProvider`]; it must not know whether inference happens
//! via Ollama, llama.cpp, or anything else. Ollama is the v0 target.
//!
//! `provider` (the abstraction) and `model` (which model + settings) are kept as separate
//! concepts so a model can be re-pointed at a different runtime without changing callers.

pub mod model;
pub mod ollama;
pub mod provider;

pub use provider::{LlmProvider, LlmRequest, LlmResponse};
