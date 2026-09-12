//! The ASR abstraction the pipeline depends on.

use std::path::PathBuf;

use async_trait::async_trait;

use crate::domain::Transcript;

/// Audio handed to an ASR provider. For v0 this is a path to prepared (mono, resampled) audio;
/// it can grow to carry PCM buffers or VAD segments later.
#[derive(Debug, Clone)]
pub struct AudioInput {
    pub path: PathBuf,
    /// Optional language hint (e.g. "en"); `None` means auto-detect / multilingual.
    pub language_hint: Option<String>,
}

impl AudioInput {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            language_hint: None,
        }
    }
}

/// Errors an ASR provider can produce.
#[derive(Debug, thiserror::Error)]
pub enum AsrError {
    /// The backend is a defined boundary but not wired up yet. Honest, not a silent stub.
    #[error("ASR backend '{0}' is not implemented yet")]
    NotImplemented(&'static str),
    #[error("audio input not found: {0}")]
    InputNotFound(PathBuf),
    #[error("transcription failed: {0}")]
    Failed(String),
}

/// Turns prepared audio into a canonical [`Transcript`]. The pipeline knows only this trait.
#[async_trait]
pub trait AsrProvider: Send + Sync {
    /// A short identifier for logging/diagnostics (e.g. "whisper", "fixture").
    fn name(&self) -> &'static str;

    /// Transcribe the given audio into a [`Transcript`].
    async fn transcribe(&self, audio: &AudioInput) -> Result<Transcript, AsrError>;
}
