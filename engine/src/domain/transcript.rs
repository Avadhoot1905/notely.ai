//! The canonical transcript: the deterministic, source-of-truth text of the meeting.
//!
//! Produced by the ASR stage (plus diarization) and consumed by the AI stage. It carries
//! timestamps so downstream evidence spans can point back into it.

use serde::{Deserialize, Serialize};

/// A contiguous span of recognized speech attributed to one speaker.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptSegment {
    /// Speaker id matching a [`super::Participant::id`], if diarization ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speaker_id: Option<String>,
    pub start: f64,
    pub end: f64,
    pub text: String,
    /// Detected language tag (e.g. "en", "hi") for multilingual meetings, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// ASR confidence for this segment in [0,1], when the provider reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}

/// The full ordered transcript for a meeting.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Transcript {
    pub segments: Vec<TranscriptSegment>,
}

impl Transcript {
    /// Distinct speaker ids in order of first appearance.
    pub fn speaker_ids(&self) -> Vec<String> {
        let mut seen = Vec::new();
        for seg in &self.segments {
            if let Some(id) = &seg.speaker_id {
                if !seen.iter().any(|s| s == id) {
                    seen.push(id.clone());
                }
            }
        }
        seen
    }

    /// Render the transcript as `speaker: text` lines, suitable for prompting an LLM.
    /// This is a deterministic textual view — not an LLM call.
    pub fn to_prompt_text(&self) -> String {
        let mut out = String::new();
        for seg in &self.segments {
            let speaker = seg.speaker_id.as_deref().unwrap_or("Unknown");
            out.push_str(speaker);
            out.push_str(": ");
            out.push_str(seg.text.trim());
            out.push('\n');
        }
        out
    }
}
