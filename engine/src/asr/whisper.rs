//! Whisper-based [`super::AsrProvider`] implementation (the v0 default).
//!
//! TODO(v0): integrate whisper.cpp (or equivalent), load the model described by a manifest
//! in `models/manifests/whisper.yaml`, and map its output to [`crate::domain::Transcript`].

use crate::domain::Transcript;

use super::AsrProvider;

/// Local Whisper transcriber. Model/runtime handles will be added when implemented.
#[derive(Default)]
pub struct WhisperProvider;

impl AsrProvider for WhisperProvider {
    fn transcribe(&self, _audio_path: &str) -> anyhow::Result<Transcript> {
        anyhow::bail!("WhisperProvider::transcribe not implemented")
    }
}
