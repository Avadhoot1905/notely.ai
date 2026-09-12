//! Semantic meeting analysis — turning a transcript into a validated [`MeetingIr`].
//!
//! This layer performs the reasoning stages over domain types. It asks the [`crate::llm`] layer
//! for a schema-constrained generation and does NOT care which runtime serves the model.
//!
//! Three separable concerns:
//!   - [`extraction`] — one schema-constrained LLM call producing the raw structured IR.
//!   - [`synthesis`]  — deterministic assembly/normalization of that IR.
//!   - [`validation`] — deterministic checks before the IR is accepted.
//!
//! See `docs/ai-engine.md`.

pub mod extraction;
pub mod provider;
pub mod synthesis;
pub mod validation;

use std::sync::Arc;

use async_trait::async_trait;

use crate::domain::{MeetingIr, Transcript};
use crate::llm::LlmProvider;

pub use provider::{AiAnalyzer, AiError, AnalysisContext};

/// The concrete AI engine: extraction → synthesis → validation over an [`LlmProvider`].
pub struct LlmAiEngine {
    llm: Arc<dyn LlmProvider>,
}

impl LlmAiEngine {
    pub fn new(llm: Arc<dyn LlmProvider>) -> Self {
        Self { llm }
    }
}

#[async_trait]
impl AiAnalyzer for LlmAiEngine {
    async fn analyze(
        &self,
        transcript: &Transcript,
        context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError> {
        // 1. Extraction — the single LLM call, constrained to the IR JSON schema.
        let request = extraction::build_request(transcript, context);
        let response = self.llm.generate(request).await?;
        let extracted = extraction::parse_ir(&response.text)?;

        // 2. Synthesis — deterministic assembly/normalization.
        let ir = synthesis::synthesize(extracted, transcript, context);

        // 3. Validation — reject well-typed-but-useless output.
        validation::validate(&ir).map_err(|errs| AiError::Validation(errs.join("; ")))?;

        Ok(ir)
    }
}
