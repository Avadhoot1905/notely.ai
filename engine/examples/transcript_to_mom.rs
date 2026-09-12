//! Manual end-to-end smoke runner: transcript fixture → Ollama/Qwen → Meeting IR → Markdown.
//!
//! Requires a running local Ollama with the configured model (see `models/manifests/qwen3.yaml`).
//!
//! ```bash
//! # default fixture:
//! cargo run -p notely-engine --example transcript_to_mom
//! # or a specific transcript JSON:
//! cargo run -p notely-engine --example transcript_to_mom -- path/to/transcript.json
//! ```
//!
//! Configure via NOTELY_OLLAMA_MODEL / NOTELY_OLLAMA_URL.

use std::sync::Arc;

use notely_engine::ai::{AiAnalyzer, AnalysisContext, LlmAiEngine};
use notely_engine::config::OllamaConfig;
use notely_engine::domain::Transcript;
use notely_engine::llm::{LlmProvider, OllamaProvider};
use notely_engine::renderer::{json, markdown};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let default_fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../data/fixtures/transcripts/product-planning.json"
    );
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| default_fixture.to_string());

    let transcript: Transcript = serde_json::from_str(&std::fs::read_to_string(&path)?)?;
    println!(
        "Loaded transcript: {} segment(s) from {path}",
        transcript.segments.len()
    );

    let config = OllamaConfig::default();
    let provider = OllamaProvider::new(&config)?;
    provider
        .health()
        .await
        .map_err(|e| anyhow::anyhow!("Ollama not reachable at {}: {e}", config.base_url))?;
    println!("Using model '{}' at {}", config.model, config.base_url);

    let engine = LlmAiEngine::new(Arc::new(provider));
    let ir = engine
        .analyze(
            &transcript,
            &AnalysisContext {
                title: Some("Product Planning".into()),
            },
        )
        .await?;

    println!("\n===== Meeting IR (JSON) =====\n{}", json::render(&ir)?);
    println!(
        "\n===== Rendered MOM (Markdown) =====\n{}",
        markdown::render_with_title(&ir, "Product Planning")
    );
    Ok(())
}
