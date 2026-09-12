//! The ASR abstraction the pipeline depends on.

use crate::domain::Transcript;

/// Turns prepared audio into a canonical [`Transcript`].
///
/// Implementations own all backend detail (model files, threading, language config).
/// The pipeline only knows this trait.
pub trait AsrProvider {
    /// Transcribe the audio at `audio_path` into a [`Transcript`].
    ///
    /// TODO(v0): finalize the input type (path vs. PCM buffer vs. VAD segments) and errors.
    fn transcribe(&self, audio_path: &str) -> anyhow::Result<Transcript>;
}
