//! Media processing: getting clean, ASR-ready audio out of arbitrary input.
//!
//! Responsibilities for v0: audio extraction/normalization via FFmpeg and voice-activity
//! detection (VAD) to segment speech. This is deliberately NOT a general media framework —
//! only what the pipeline needs to feed the ASR stage.

pub mod ffmpeg;
pub mod vad;
