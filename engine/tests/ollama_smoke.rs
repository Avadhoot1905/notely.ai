//! End-to-end smoke test against a REAL local Ollama + Qwen model.
//!
//! Ignored by default so the normal suite never depends on Ollama being installed. Run manually:
//!
//! ```bash
//! cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture
//! ```
//!
//! It proves the most important backend path:
//!   fixture transcript → AI engine → Ollama/Qwen → structured Meeting IR → validation → Markdown.
//!
//! Override the model/URL with NOTELY_OLLAMA_MODEL / NOTELY_OLLAMA_URL.

use std::sync::Arc;

use notely_engine::ai::{AiAnalyzer, AnalysisContext, LlmAiEngine};
use notely_engine::config::OllamaConfig;
use notely_engine::domain::Transcript;
use notely_engine::llm::{LlmProvider, OllamaProvider};
use notely_engine::renderer::markdown;

fn load_fixture_transcript() -> Transcript {
    // engine/tests/ -> repo root -> data/fixtures/...
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../data/fixtures/transcripts/product-planning.json"
    );
    let json = std::fs::read_to_string(path).expect("fixture transcript exists");
    serde_json::from_str(&json).expect("fixture transcript parses")
}

#[tokio::test]
#[ignore = "requires a running local Ollama with the configured Qwen model"]
async fn transcript_to_meeting_ir_via_ollama() {
    let config = OllamaConfig::default();
    let provider = OllamaProvider::new(&config).expect("provider builds");

    // Skip gracefully if the runtime isn't reachable, so `--ignored` runs elsewhere don't fail.
    if provider.health().await.is_err() {
        eprintln!("Ollama not reachable at {} — skipping", config.base_url);
        return;
    }

    let engine = LlmAiEngine::new(Arc::new(provider));
    let transcript = load_fixture_transcript();
    let context = AnalysisContext {
        title: Some("Product Planning".into()),
    };

    let ir = engine
        .analyze(&transcript, &context)
        .await
        .expect("analysis produces a valid Meeting IR");

    // Structural expectations. Content will vary run-to-run, so assert shape, not exact strings.
    assert!(!ir.summary.trim().is_empty(), "summary should be populated");
    assert!(
        !ir.participants.is_empty(),
        "participants should be backfilled from the transcript"
    );

    let mom = markdown::render_with_title(&ir, "Product Planning");
    assert!(mom.contains("## Summary"));
    assert!(mom.contains("## Action Items"));

    eprintln!(
        "\n----- Meeting IR (JSON) -----\n{}",
        serde_json::to_string_pretty(&ir).unwrap()
    );
    eprintln!("\n----- Rendered MOM -----\n{mom}");
}
