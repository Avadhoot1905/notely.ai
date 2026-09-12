//! Whisper-based [`AsrProvider`] — an OPTIONAL provider (not the v0 default; Qwen3-ASR is).
//!
//! This is a real boundary with NO real implementation yet: `transcribe` returns
//! [`AsrError::NotImplemented`] rather than pretending. Integrating whisper.cpp (loading the model
//! from `models/manifests/whisper.yaml` and mapping its segments to [`Transcript`]) is future work.
//! It is kept behind the same trait so it can be selected via `NOTELY_ASR_PROVIDER=whisper` later.

use async_trait::async_trait;

use crate::domain::Transcript;

use super::provider::{AsrError, AsrProvider, AudioInput};

/// Placeholder for the local Whisper transcriber.
#[derive(Default)]
pub struct WhisperProvider;

#[async_trait]
impl AsrProvider for WhisperProvider {
    fn name(&self) -> &'static str {
        "whisper"
    }

    async fn transcribe(&self, _audio: &AudioInput) -> Result<Transcript, AsrError> {
        Err(AsrError::NotImplemented("whisper"))
    }
}
