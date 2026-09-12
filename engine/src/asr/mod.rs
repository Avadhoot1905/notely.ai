//! Automatic speech recognition (ASR).
//!
//! The pipeline talks to an [`AsrProvider`] abstraction, never to a concrete backend.
//!
//! ```text
//!                 ASR Provider
//!                      │
//!            ┌─────────┼─────────┐
//!            ▼         ▼         ▼
//!        Qwen3-ASR   Whisper   Fixture
//!         default    optional   tests
//! ```
//!
//! The default is **Qwen3-ASR**, which runs on a *separate* HTTP runtime (not Ollama). See
//! [`qwen3_asr`] and `models/manifests/qwen3-asr.yaml`.

pub mod provider;
pub mod qwen3_asr;
pub mod whisper;

use std::sync::Arc;

use async_trait::async_trait;

use crate::config::{AsrConfig, AsrProviderKind};
use crate::domain::Transcript;

pub use provider::{AsrError, AsrProvider, AudioInput};
pub use qwen3_asr::Qwen3AsrProvider;
pub use whisper::WhisperProvider;

/// Build the configured ASR provider. The default is Qwen3-ASR (separate runtime).
///
/// `Fixture` yields an empty-transcript provider; it exists so the engine still builds when
/// explicitly configured for offline dev — tests construct [`FixtureAsrProvider`] directly with a
/// real fixture transcript.
pub fn from_config(config: &AsrConfig) -> Result<Arc<dyn AsrProvider>, AsrError> {
    Ok(match config.provider {
        AsrProviderKind::Qwen3Asr => Arc::new(Qwen3AsrProvider::new(config)?),
        AsrProviderKind::Whisper => Arc::new(WhisperProvider),
        AsrProviderKind::Fixture => Arc::new(FixtureAsrProvider::new(Transcript::default())),
    })
}

/// A deterministic ASR provider that returns a preset transcript regardless of input.
///
/// Not a pretend-Qwen3-ASR: it exists so the pipeline and tests can exercise the ASR boundary
/// without a real transcription runtime.
pub struct FixtureAsrProvider {
    transcript: Transcript,
}

impl FixtureAsrProvider {
    pub fn new(transcript: Transcript) -> Self {
        Self { transcript }
    }
}

#[async_trait]
impl AsrProvider for FixtureAsrProvider {
    fn name(&self) -> &'static str {
        "fixture"
    }

    async fn transcribe(&self, _audio: &AudioInput) -> Result<Transcript, AsrError> {
        Ok(self.transcript.clone())
    }
}
