//! The semantic-operations abstraction the pipeline depends on.
//!
//! An [`AiAnalyzer`] turns a [`Transcript`] into a validated [`MeetingIr`]. It is implemented on
//! top of an [`LlmProvider`](crate::llm::LlmProvider) but callers never see the LLM: they ask for
//! meaning, not tokens.

use async_trait::async_trait;

use crate::domain::{MeetingIr, Transcript};
use crate::llm::LlmError;

/// Optional context that helps analysis but isn't part of the transcript.
#[derive(Debug, Clone, Default)]
pub struct AnalysisContext {
    /// A known meeting title, if any.
    pub title: Option<String>,
}

/// Errors from the AI layer.
#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("LLM error: {0}")]
    Llm(#[from] LlmError),
    /// The model returned something that is not the expected structured IR.
    #[error("could not parse structured Meeting IR from model output: {0}")]
    Parse(String),
    /// The parsed IR failed validation.
    #[error("Meeting IR failed validation: {0}")]
    Validation(String),
}

/// Produces structured meeting intelligence from a canonical transcript.
#[async_trait]
pub trait AiAnalyzer: Send + Sync {
    /// Analyze `transcript` into a validated [`MeetingIr`].
    async fn analyze(
        &self,
        transcript: &Transcript,
        context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError>;
}
