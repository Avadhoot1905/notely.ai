//! Two-pass AI pipeline with a MOCK LLM (no Ollama). Verifies that per-chunk extraction and
//! synthesis are deserialized + validated, that provenance is reattached, and that an owner the
//! synthesis model invents (not in the transcript/findings) is dropped rather than trusted.

use std::sync::Arc;

use async_trait::async_trait;

use notely_engine::ai::{analyze, AnalysisContext, LlmAiEngine};
use notely_engine::config::ChunkingConfig;
use notely_engine::domain::{Transcript, TranscriptSegment};
use notely_engine::llm::{GenerateRequest, GenerateResponse, LlmError, LlmProvider};
use notely_engine::preprocess::prepare;

/// Returns canned findings JSON for extraction calls and canned IR JSON for the synthesis call.
struct MockLlm;

const FINDINGS_JSON: &str = r#"{
  "topics": [],
  "decisions": [
    { "decision": "ship the migration", "evidence": [{ "quote": "Avi will ship the migration by Friday" }] }
  ],
  "action_items": [
    { "description": "ship the migration", "owner": "Avi", "deadline": "Friday",
      "evidence": [{ "quote": "Avi will ship the migration by Friday" }] }
  ],
  "open_questions": [],
  "risks": []
}"#;

// Synthesis output invents owner "Bob" (not in the transcript or findings) — the reconciler must
// drop it. Deadline "Friday" is in the transcript and must be kept.
const IR_JSON: &str = r#"{
  "summary": "The team discussed shipping the migration.",
  "participants": [],
  "topics": [],
  "decisions": [ { "decision": "Ship the migration" } ],
  "action_items": [ { "description": "Ship the migration", "owner": "Bob", "deadline": "Friday" } ],
  "open_questions": [],
  "risks": []
}"#;

#[async_trait]
impl LlmProvider for MockLlm {
    async fn generate(&self, request: GenerateRequest) -> Result<GenerateResponse, LlmError> {
        // Synthesis prompt asks to "Consolidate"; extraction prompt is per-excerpt.
        let text = if request.prompt.contains("Consolidate") {
            IR_JSON
        } else {
            FINDINGS_JSON
        };
        Ok(GenerateResponse {
            text: text.to_string(),
            model: "mock".into(),
        })
    }
    async fn health(&self) -> Result<(), LlmError> {
        Ok(())
    }
}

fn transcript() -> Transcript {
    Transcript {
        segments: vec![TranscriptSegment {
            speaker_id: Some("S1".into()),
            start: 0.0,
            end: 5.0,
            text: "Avi will ship the migration by Friday".into(),
            language: None,
            confidence: None,
        }],
    }
}

#[tokio::test]
async fn two_pass_analysis_reattaches_provenance_and_drops_invented_owner() {
    let engine = LlmAiEngine::new(Arc::new(MockLlm));
    let prepared = prepare(&transcript(), &ChunkingConfig::default());
    assert_eq!(prepared.chunks.len(), 1);

    let ir = analyze(
        &engine,
        &prepared,
        &AnalysisContext {
            title: Some("Sync".into()),
        },
    )
    .await
    .expect("analysis succeeds and validates");

    // Summary + participants.
    assert!(ir.summary.contains("migration"));
    assert_eq!(
        ir.participants[0].id, "S1",
        "participant backfilled from transcript"
    );

    // Decision evidence was reattached from the extraction findings (chunk-stamped).
    assert_eq!(ir.decisions.len(), 1);
    let ev = &ir.decisions[0].evidence;
    assert!(!ev.is_empty(), "decision has evidence");
    assert_eq!(
        ev[0].chunk_id.as_deref(),
        Some("chunk-0"),
        "provenance chunk id present"
    );

    // Anti-invention guard: "Bob" is dropped; "Friday" (in transcript) is kept.
    let a = &ir.action_items[0];
    assert_eq!(a.owner, None, "invented owner 'Bob' dropped");
    assert_eq!(
        a.deadline.as_deref(),
        Some("Friday"),
        "transcript-supported deadline kept"
    );
}

#[tokio::test]
async fn empty_transcript_is_handled_without_an_llm_call() {
    let engine = LlmAiEngine::new(Arc::new(MockLlm));
    let prepared = prepare(&Transcript::default(), &ChunkingConfig::default());
    let ir = analyze(&engine, &prepared, &AnalysisContext::default())
        .await
        .unwrap();
    assert!(ir.summary.to_lowercase().contains("no transcript"));
    assert!(ir.action_items.is_empty());
}
