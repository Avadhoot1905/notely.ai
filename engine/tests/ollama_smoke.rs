//! End-to-end AI smoke test against a REAL local Ollama + Qwen model.
//!
//! Ignored by default so the normal suite never depends on Ollama. Run manually:
//!
//! ```bash
//! cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture
//! ```
//!
//! Proves the two-pass AI path:
//!   fixture transcript → deterministic chunking → Qwen3 1.7B extraction (per chunk)
//!   → synthesis → validated Meeting IR → deterministic Markdown.
//!
//! Override the model/URL with NOTELY_LLM_MODEL / NOTELY_OLLAMA_URL.

use std::sync::Arc;

use notely_engine::ai::{analyze, AnalysisContext, LlmAiEngine};
use notely_engine::config::{ChunkingConfig, OllamaConfig};
use notely_engine::domain::Transcript;
use notely_engine::llm::{LlmProvider, OllamaProvider};
use notely_engine::preprocess::prepare;
use notely_engine::renderer::markdown;

fn load_fixture_transcript() -> Transcript {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../data/fixtures/transcripts/weekly-eng-sync.json"
    );
    let json = std::fs::read_to_string(path).expect("fixture transcript exists");
    serde_json::from_str(&json).expect("fixture transcript parses")
}

#[tokio::test]
#[ignore = "requires a running local Ollama with the configured Qwen model"]
async fn transcript_to_meeting_ir_via_ollama() {
    let config = OllamaConfig::default();
    let provider = OllamaProvider::new(&config).expect("provider builds");

    if provider.health().await.is_err() {
        eprintln!("Ollama not reachable at {} — skipping", config.base_url);
        return;
    }

    let engine = LlmAiEngine::new(Arc::new(provider));
    let transcript = load_fixture_transcript();
    let prepared = prepare(&transcript, &ChunkingConfig::default());
    let context = AnalysisContext {
        title: Some("Weekly Eng Sync".into()),
    };

    let ir = analyze(&engine, &prepared, &context)
        .await
        .expect("analysis produces a valid Meeting IR");

    // Structural expectations. Content varies run-to-run, so assert shape, not exact strings.
    assert!(!ir.summary.trim().is_empty(), "summary should be populated");
    assert!(
        !ir.participants.is_empty(),
        "participants backfilled from transcript"
    );

    // No fabricated owners: any owner present must appear in the transcript text.
    let transcript_lower = transcript
        .segments
        .iter()
        .map(|s| s.text.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ");
    for a in &ir.action_items {
        if let Some(owner) = &a.owner {
            assert!(
                transcript_lower.contains(&owner.to_lowercase()),
                "owner '{owner}' was not in the transcript (possible fabrication)"
            );
        }
    }

    let mom = markdown::render_with_title(&ir, "Weekly Eng Sync");
    assert!(mom.contains("## Summary"));
    assert!(mom.contains("## Action Items"));
    assert!(mom.contains("| Action | Owner | Deadline | Status |"));

    eprintln!(
        "\n----- Meeting IR (JSON) -----\n{}",
        serde_json::to_string_pretty(&ir).unwrap()
    );
    eprintln!("\n----- Rendered MOM -----\n{mom}");
}
