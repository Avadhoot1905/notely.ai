//! Deterministic transcript preparation — the "deterministic Rust" stage between ASR and the LLM.
//!
//! This is intentionally NOT the LLM's job. Rust performs the mechanical work — whitespace cleanup,
//! segment ordering, timestamp normalization, and chunking — so the small Qwen model only does
//! semantic work. The **raw** ASR transcript is preserved unchanged; normalization produces a
//! separate cleaned copy and never rewrites wording.
//!
//! ```text
//! raw Transcript
//!     ├── (kept verbatim)
//!     └── normalize → normalized Transcript → chunk → Vec<Chunk> → AI extraction
//! ```

pub mod chunking;

use crate::config::ChunkingConfig;
use crate::domain::{Transcript, TranscriptSegment};

pub use chunking::{chunk_segments, segments_to_text, Chunk};

/// The output of transcript preparation: the untouched raw transcript, a normalized copy, and the
/// deterministic chunks derived from it.
#[derive(Debug, Clone)]
pub struct PreparedTranscript {
    /// The original ASR output, preserved exactly.
    pub raw: Transcript,
    /// A cleaned copy (whitespace + ordering + timestamp normalization). Wording is NOT altered.
    pub normalized: Transcript,
    /// Deterministic chunks over the normalized transcript.
    pub chunks: Vec<Chunk>,
}

/// Normalize + chunk a raw transcript. Deterministic and side-effect free.
pub fn prepare(raw: &Transcript, config: &ChunkingConfig) -> PreparedTranscript {
    let normalized = normalize(raw);
    let chunks = chunk_segments(&normalized.segments, config);
    PreparedTranscript {
        raw: raw.clone(),
        normalized,
        chunks,
    }
}

/// Produce a normalized copy of the transcript.
///
/// - collapses internal whitespace and trims each segment's text (mechanical only — no rewording);
/// - drops segments whose text is empty after trimming;
/// - clamps `end >= start` and non-negative timestamps;
/// - orders segments by start time (stable).
pub fn normalize(raw: &Transcript) -> Transcript {
    let mut segments: Vec<TranscriptSegment> = raw
        .segments
        .iter()
        .filter_map(|seg| {
            let text = collapse_whitespace(&seg.text);
            if text.is_empty() {
                return None;
            }
            let start = seg.start.max(0.0);
            let end = seg.end.max(start);
            Some(TranscriptSegment {
                speaker_id: seg.speaker_id.clone(),
                start,
                end,
                text,
                language: seg.language.clone(),
                confidence: seg.confidence,
            })
        })
        .collect();

    // Stable sort by start time keeps deterministic ordering for equal timestamps.
    segments.sort_by(|a, b| {
        a.start
            .partial_cmp(&b.start)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Transcript { segments }
}

/// Collapse runs of whitespace to single spaces and trim. Does not change words.
fn collapse_whitespace(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(start: f64, end: f64, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            speaker_id: Some("S1".into()),
            start,
            end,
            text: text.to_string(),
            language: None,
            confidence: None,
        }
    }

    #[test]
    fn normalize_cleans_whitespace_and_orders_without_rewording() {
        let raw = Transcript {
            segments: vec![
                seg(5.0, 6.0, "second   line\n"),
                seg(1.0, 2.0, "  first    line  "),
                seg(3.0, 3.0, "   "), // empty after trim -> dropped
            ],
        };
        let n = normalize(&raw);
        assert_eq!(n.segments.len(), 2);
        assert_eq!(n.segments[0].text, "first line"); // ordered by start, whitespace collapsed
        assert_eq!(n.segments[1].text, "second line");
        // raw is untouched.
        assert_eq!(raw.segments.len(), 3);
    }

    #[test]
    fn prepare_is_deterministic() {
        let raw = Transcript {
            segments: vec![seg(0.0, 1.0, "hello world"), seg(1.0, 2.0, "again")],
        };
        let a = prepare(&raw, &ChunkingConfig::default());
        let b = prepare(&raw, &ChunkingConfig::default());
        assert_eq!(a.chunks, b.chunks);
        assert_eq!(a.raw, raw); // raw preserved
    }
}
