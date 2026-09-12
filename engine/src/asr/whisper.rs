//! Whisper-based [`AsrProvider`] — the intended v0 default.
//!
//! This is a real boundary with NO real implementation yet: `transcribe` returns
//! [`AsrError::NotImplemented`] rather than pretending. Integrating whisper.cpp (loading the model
//! from `models/manifests/whisper.yaml` and mapping its segments to [`Transcript`]) is future work.
//! Until then, audio→transcript is unavailable; the transcript-import path (see the pipeline) is
//! the supported flow, and tests use the fixture provider.

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
