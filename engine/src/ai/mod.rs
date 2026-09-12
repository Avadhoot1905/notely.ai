//! Semantic meeting analysis — turning a transcript into a structured [`MeetingIr`].
//!
//! This layer performs the *reasoning* stages and works with domain types, not UI concepts.
//! It asks the [`llm`](crate::llm) layer for semantic operations and does NOT care which
//! runtime (Ollama, llama.cpp, …) actually serves the model.
//!
//! Three separable concerns:
//!   - [`extraction`] — pull decisions/action items/etc. out of the transcript.
//!   - [`synthesis`]  — compose an overall summary / assemble the IR.
//!   - [`validation`] — check the IR for consistency and evidence coverage.
//!
//! See `docs/ai-engine.md`.

pub mod extraction;
pub mod provider;
pub mod synthesis;
pub mod validation;

pub use provider::AiProvider;
