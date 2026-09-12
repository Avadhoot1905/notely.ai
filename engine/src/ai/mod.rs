//! Semantic meeting analysis — turning prepared transcript chunks into a validated [`MeetingIr`].
//!
//! Two deliberately separate LLM passes over domain types, plus deterministic glue:
//!   - [`extraction`] — one schema-constrained call per chunk → [`ChunkFindings`];
//!   - [`synthesis`]  — one call consolidating all findings → [`MeetingIr`], then deterministic
//!     provenance reconciliation and an anti-invention guard;
//!   - [`validation`] — deterministic checks before the IR is accepted.
//!
//! The AI layer asks [`crate::llm`] for schema-constrained generations; it never speaks HTTP to a
//! runtime. See `docs/ai-engine.md`.

pub mod extraction;
pub mod findings;
pub mod provider;
pub mod schema;
pub mod synthesis;
pub mod validation;

use std::sync::Arc;

use async_trait::async_trait;

use crate::domain::{MeetingIr, Transcript};
use crate::llm::{GenerateRequest, LlmProvider};
use crate::preprocess::{Chunk, PreparedTranscript};

pub use findings::{ChunkFindings, MergedFindings};
pub use provider::{AiAnalyzer, AiError, AnalysisContext};

/// The concrete AI engine: per-chunk extraction + consolidation synthesis over an [`LlmProvider`].
pub struct LlmAiEngine {
    llm: Arc<dyn LlmProvider>,
}

impl LlmAiEngine {
    pub fn new(llm: Arc<dyn LlmProvider>) -> Self {
        Self { llm }
    }

    /// Generate, parsing the result; on a parse failure, retry ONCE with a stricter reminder before
    /// giving up. This is the controlled repair path — malformed output is never accepted as valid.
    async fn generate_parsed<T, F>(&self, request: GenerateRequest, parse: F) -> Result<T, AiError>
    where
        F: Fn(&str) -> Result<T, AiError>,
    {
        let response = self.llm.generate(request.clone()).await?;
        match parse(&response.text) {
            Ok(v) => Ok(v),
            Err(_first) => {
                // Retry with an explicit reminder appended.
                let mut retry = request;
                retry.prompt.push_str(
                    "\n\nIMPORTANT: your previous reply was not valid JSON. Reply with ONLY the \
                     JSON object, no prose or code fences.",
                );
                let response = self.llm.generate(retry).await?;
                parse(&response.text)
            }
        }
    }
}

#[async_trait]
impl AiAnalyzer for LlmAiEngine {
    async fn extract_chunk(
        &self,
        chunk: &Chunk,
        context: &AnalysisContext,
    ) -> Result<ChunkFindings, AiError> {
        let request = extraction::build_request(chunk, context);
        self.generate_parsed(request, |raw| extraction::parse_findings(raw, chunk))
            .await
    }

    async fn synthesize(
        &self,
        findings: &[ChunkFindings],
        transcript: &Transcript,
        context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError> {
        let merged = MergedFindings::from_chunks(findings);
        let request = synthesis::build_request(&merged, context);
        let ir = self.generate_parsed(request, synthesis::parse_ir).await?;
        Ok(synthesis::reconcile(ir, &merged, transcript))
    }
}

/// Run the full two-pass analysis over a prepared transcript, returning a validated Meeting IR.
///
/// Convenience for callers (tests, example, the smoke test) that don't need per-stage progress
/// events; the orchestrator drives the same passes inline so it can emit events.
pub async fn analyze(
    ai: &dyn AiAnalyzer,
    prepared: &PreparedTranscript,
    context: &AnalysisContext,
) -> Result<MeetingIr, AiError> {
    // Empty transcript: deterministic, no LLM call, no invention.
    if prepared.chunks.is_empty() {
        return Ok(MeetingIr {
            summary: "No transcript content was available to analyze.".to_string(),
            ..Default::default()
        });
    }

    let mut findings = Vec::with_capacity(prepared.chunks.len());
    for chunk in &prepared.chunks {
        findings.push(ai.extract_chunk(chunk, context).await?);
    }

    let ir = ai
        .synthesize(&findings, &prepared.normalized, context)
        .await?;
    validation::validate(&ir).map_err(|errs| AiError::Validation(errs.join("; ")))?;
    Ok(ir)
}
