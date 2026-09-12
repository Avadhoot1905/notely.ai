//! The semantic-operations abstraction the pipeline depends on.
//!
//! An `AiProvider` orchestrates extraction → synthesis → validation to produce a validated
//! [`MeetingIr`] from a [`Transcript`]. It is implemented on top of an
//! [`llm::LlmProvider`](crate::llm::LlmProvider); it never speaks a runtime protocol itself.

use crate::domain::{MeetingIr, Transcript};

/// Produces structured meeting intelligence from a canonical transcript.
pub trait AiProvider {
    /// Analyze `transcript` into a validated [`MeetingIr`].
    ///
    /// TODO(v0): thread through options (language, verification mode) and error types.
    fn analyze(&self, transcript: &Transcript) -> anyhow::Result<MeetingIr>;
}
