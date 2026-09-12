//! Automatic speech recognition (ASR).
//!
//! The pipeline talks to an [`AsrProvider`] abstraction, never directly to Whisper.
//!
//! ```text
//! AsrProvider
//!   ├── Whisper (boundary defined; not implemented yet)
//!   └── Fixture (deterministic; for tests and the transcript-first dev path)
//! ```

pub mod provider;
pub mod whisper;

use async_trait::async_trait;

use crate::domain::Transcript;

pub use provider::{AsrError, AsrProvider, AudioInput};
pub use whisper::WhisperProvider;

/// A deterministic ASR provider that returns a preset transcript regardless of input.
///
/// Not a pretend-Whisper: it exists so the pipeline and tests can exercise the ASR boundary
/// without a real transcription engine. Useful in unit tests and the end-to-end smoke path.
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
