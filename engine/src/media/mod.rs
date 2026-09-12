//! Media processing: getting clean, ASR-ready audio out of arbitrary input.
//!
//! Responsibilities for v0: inspect media, extract/normalize audio (FFmpeg), and expose a VAD
//! boundary. This is deliberately NOT a general media framework — only what the pipeline needs to
//! feed the ASR stage. The pipeline depends on the [`MediaProcessor`] trait, not on FFmpeg.

pub mod ffmpeg;
pub mod vad;

use std::path::{Path, PathBuf};

use async_trait::async_trait;

pub use ffmpeg::FfmpegMediaProcessor;
pub use vad::{SpeechSegment, Vad};

/// What we learned about an input media file.
#[derive(Debug, Clone, Default)]
pub struct MediaInfo {
    pub duration_seconds: Option<f64>,
    pub has_audio: bool,
}

/// Audio prepared for ASR (mono, resampled WAV on disk).
#[derive(Debug, Clone)]
pub struct PreparedAudio {
    pub path: PathBuf,
    pub sample_rate: u32,
    pub channels: u16,
}

/// How to prepare audio for ASR. Sensible ASR defaults (16 kHz mono).
#[derive(Debug, Clone)]
pub struct ExtractOptions {
    pub sample_rate: u32,
    pub channels: u16,
}

impl Default for ExtractOptions {
    fn default() -> Self {
        Self {
            sample_rate: 16_000,
            channels: 1,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum MediaError {
    #[error("input media not found: {0}")]
    InputNotFound(PathBuf),
    #[error("media tool unavailable: {0}")]
    ToolUnavailable(String),
    #[error("media processing failed: {0}")]
    Failed(String),
}

/// Inspect and normalize media for downstream ASR.
#[async_trait]
pub trait MediaProcessor: Send + Sync {
    /// Inspect a media file.
    async fn probe(&self, input: &Path) -> Result<MediaInfo, MediaError>;

    /// Extract normalized audio suitable for ASR, writing it under `out_dir`.
    async fn extract_audio(
        &self,
        input: &Path,
        out_dir: &Path,
        options: &ExtractOptions,
    ) -> Result<PreparedAudio, MediaError>;
}
