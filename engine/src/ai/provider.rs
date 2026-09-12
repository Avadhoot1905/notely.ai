//! The semantic-operations abstraction the pipeline depends on.
//!
//! The AI layer exposes the two reasoning passes explicitly so the orchestrator can drive them and
//! report progress: per-chunk [`extract`](AiAnalyzer::extract_chunk) and global
//! [`synthesize`](AiAnalyzer::synthesize). Callers never see the LLM — they ask for meaning, not
//! tokens, and never speak HTTP to Ollama.

use async_trait::async_trait;

use crate::domain::{MeetingIr, Transcript};
use crate::llm::LlmError;
use crate::preprocess::Chunk;

use super::findings::ChunkFindings;

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
    /// The model returned something that is not the expected structured JSON.
    #[error("could not parse structured output from model: {0}")]
    Parse(String),
    /// The parsed IR failed validation.
    #[error("Meeting IR failed validation: {0}")]
    Validation(String),
}

/// Produces structured meeting intelligence from prepared transcript chunks.
///
/// Two passes, deliberately separate (see `docs/ai-engine.md`):
///   1. [`extract_chunk`](Self::extract_chunk) — one schema-constrained call per chunk;
///   2. [`synthesize`](Self::synthesize) — consolidate all findings into the Meeting IR.
#[async_trait]
pub trait AiAnalyzer: Send + Sync {
    /// Extract structured findings from a single prepared chunk.
    async fn extract_chunk(
        &self,
        chunk: &Chunk,
        context: &AnalysisContext,
    ) -> Result<ChunkFindings, AiError>;

    /// Consolidate per-chunk findings into a coherent Meeting IR. `transcript` is the normalized
    /// transcript, used for participant backfill and provenance reconciliation.
    async fn synthesize(
        &self,
        findings: &[ChunkFindings],
        transcript: &Transcript,
        context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError>;
}
