//! Vault-wide retrieval: full-text search over the user's notes and source-grounded answering.
//!
//! This is the "Retrieve" half of Notely's core loop (Capture → Understand → Connect → Persist →
//! Retrieve). It reads the same Markdown notes the desktop app owns, keeps a cheap incremental
//! FTS5 index of them ([`index`]), and answers questions strictly from what it finds ([`qa`]).
//!
//! Two boundaries are respected: the LLM is reached only through [`crate::llm::LlmProvider`], and
//! the index is derived data in its own database — losing it costs nothing but a re-sync.

pub mod chunker;
pub mod index;
pub mod qa;

pub use index::{Passage, SearchError, SearchIndex, SyncStats};
