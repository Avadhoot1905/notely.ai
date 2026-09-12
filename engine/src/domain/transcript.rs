//! The canonical transcript: the deterministic, source-of-truth text of the meeting.
//!
//! Produced by the ASR stage (plus diarization) and consumed by the AI stage. It carries
//! timestamps so downstream evidence spans can point back into it.

use serde::{Deserialize, Serialize};

/// A contiguous span of recognized speech attributed to one speaker.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptSegment {
    /// Speaker id matching a [`super::Participant::id`], if diarization ran.
    pub speaker_id: Option<String>,
    pub start: f64,
    pub end: f64,
    pub text: String,
    /// Detected language tag (e.g. "en", "hi") for multilingual meetings, if known.
    pub language: Option<String>,
}

/// The full ordered transcript for a meeting.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Transcript {
    pub segments: Vec<TranscriptSegment>,
}
