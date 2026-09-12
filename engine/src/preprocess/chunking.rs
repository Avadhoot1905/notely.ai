//! Deterministic, segment-aware transcript chunking.
//!
//! Chunks are built by accumulating whole transcript segments up to an approximate character
//! budget — never by blindly splitting every N characters. Each chunk carries enough metadata to
//! trace extracted findings back to the source transcript (segment range + timestamps), plus
//! neighboring context for continuity across boundaries.
//!
//! The algorithm is pure and deterministic: the same normalized transcript + config always yields
//! the same chunks.

use serde::{Deserialize, Serialize};

use crate::config::ChunkingConfig;
use crate::domain::TranscriptSegment;

/// A contiguous slice of the transcript prepared for one extraction call.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Chunk {
    /// Stable id, e.g. `chunk-0`.
    pub id: String,
    pub index: usize,
    /// Inclusive start index into the normalized segment list.
    pub segment_start: usize,
    /// Exclusive end index into the normalized segment list.
    pub segment_end: usize,
    /// First segment start time (seconds).
    pub start: f64,
    /// Last segment end time (seconds).
    pub end: f64,
    /// `speaker: text` lines for this chunk's primary segments.
    pub text: String,
    /// The primary segments of this chunk (used for deterministic evidence grounding).
    #[serde(default)]
    pub segments: Vec<TranscriptSegment>,
    /// Tail of the previous chunk, for continuity (does not duplicate primary attribution).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preceding_context: Option<String>,
    /// Head of the next chunk, for continuity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub following_context: Option<String>,
}

impl Chunk {
    /// The text an extraction prompt should see: primary text, optionally framed by context.
    pub fn prompt_text(&self) -> String {
        let mut out = String::new();
        if let Some(before) = &self.preceding_context {
            out.push_str("[...earlier context...]\n");
            out.push_str(before);
            out.push_str("\n[...]\n");
        }
        out.push_str(&self.text);
        if let Some(after) = &self.following_context {
            out.push_str("\n[...]\n");
            out.push_str(after);
            out.push_str("\n[...later context...]");
        }
        out
    }
}

/// Render `speaker: text` lines for a slice of segments. Deterministic; no LLM.
pub fn segments_to_text(segments: &[TranscriptSegment]) -> String {
    let mut out = String::new();
    for seg in segments {
        let speaker = seg.speaker_id.as_deref().unwrap_or("Unknown");
        out.push_str(speaker);
        out.push_str(": ");
        out.push_str(seg.text.trim());
        out.push('\n');
    }
    out.trim_end().to_string()
}

/// Split normalized segments into deterministic chunks per `config`.
///
/// A chunk grows by whole segments until adding the next would exceed `max_chars` (unless the
/// chunk is still empty, so an oversized single segment becomes its own chunk). Neighboring
/// context (`context_chars`) is attached in a second pass.
pub fn chunk_segments(segments: &[TranscriptSegment], config: &ChunkingConfig) -> Vec<Chunk> {
    if segments.is_empty() {
        return Vec::new();
    }
    let max_chars = config.max_chars.max(1);

    // First pass: partition into segment ranges.
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut range_start = 0usize;
    let mut current_len = 0usize;
    for (i, seg) in segments.iter().enumerate() {
        let seg_len = seg.text.trim().len() + 1; // +1 for the joining newline
        let is_empty_chunk = i == range_start;
        if !is_empty_chunk && current_len + seg_len > max_chars {
            ranges.push((range_start, i));
            range_start = i;
            current_len = 0;
        }
        current_len += seg_len;
    }
    ranges.push((range_start, segments.len()));

    // Second pass: build chunks with text + neighboring context.
    let mut chunks: Vec<Chunk> = Vec::with_capacity(ranges.len());
    for (index, &(s, e)) in ranges.iter().enumerate() {
        let slice = &segments[s..e];
        let text = segments_to_text(slice);
        chunks.push(Chunk {
            id: format!("chunk-{index}"),
            index,
            segment_start: s,
            segment_end: e,
            start: slice.first().map(|x| x.start).unwrap_or(0.0),
            end: slice.last().map(|x| x.end).unwrap_or(0.0),
            text,
            segments: slice.to_vec(),
            preceding_context: None,
            following_context: None,
        });
    }

    // Attach context tails/heads.
    let context_chars = config.context_chars;
    if context_chars > 0 {
        let texts: Vec<String> = chunks.iter().map(|c| c.text.clone()).collect();
        for i in 0..chunks.len() {
            if i > 0 {
                chunks[i].preceding_context = Some(tail(&texts[i - 1], context_chars));
            }
            if i + 1 < texts.len() {
                chunks[i].following_context = Some(head(&texts[i + 1], context_chars));
            }
        }
    }

    chunks
}

/// Last `n` characters of `s`, aligned to a char boundary (deterministic).
fn tail(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    let start = s
        .char_indices()
        .rev()
        .take(n)
        .last()
        .map(|(i, _)| i)
        .unwrap_or(0);
    s[start..].to_string()
}

/// First `n` characters of `s`, aligned to a char boundary.
fn head(s: &str, n: usize) -> String {
    match s.char_indices().nth(n) {
        Some((idx, _)) => s[..idx].to_string(),
        None => s.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(speaker: &str, start: f64, end: f64, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            speaker_id: Some(speaker.to_string()),
            start,
            end,
            text: text.to_string(),
            language: None,
            confidence: None,
        }
    }

    #[test]
    fn empty_transcript_yields_no_chunks() {
        assert!(chunk_segments(&[], &ChunkingConfig::default()).is_empty());
    }

    #[test]
    fn short_transcript_is_a_single_chunk() {
        let segs = vec![
            seg("S1", 0.0, 1.0, "hello"),
            seg("S2", 1.0, 2.0, "hi there"),
        ];
        let chunks = chunk_segments(&segs, &ChunkingConfig::default());
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].segment_start, 0);
        assert_eq!(chunks[0].segment_end, 2);
        assert_eq!(chunks[0].start, 0.0);
        assert_eq!(chunks[0].end, 2.0);
        assert!(chunks[0].preceding_context.is_none());
        assert!(chunks[0].following_context.is_none());
    }

    #[test]
    fn splits_on_segment_boundaries_by_char_budget_and_is_deterministic() {
        let segs: Vec<_> = (0..10)
            .map(|i| seg("S1", i as f64, (i + 1) as f64, &"x".repeat(30)))
            .collect();
        let cfg = ChunkingConfig {
            max_chars: 62,
            context_chars: 10,
        };
        let a = chunk_segments(&segs, &cfg);
        let b = chunk_segments(&segs, &cfg);
        assert_eq!(a, b, "chunking must be deterministic");
        assert!(a.len() > 1, "should split into multiple chunks");
        // Ranges must be contiguous and cover all segments with no overlap.
        assert_eq!(a[0].segment_start, 0);
        for w in a.windows(2) {
            assert_eq!(w[0].segment_end, w[1].segment_start);
        }
        assert_eq!(a.last().unwrap().segment_end, 10);
        // Middle chunks carry neighbor context.
        assert!(a[1].preceding_context.is_some());
    }

    #[test]
    fn oversized_single_segment_becomes_its_own_chunk() {
        let segs = vec![
            seg("S1", 0.0, 1.0, &"y".repeat(500)),
            seg("S2", 1.0, 2.0, "ok"),
        ];
        let cfg = ChunkingConfig {
            max_chars: 50,
            context_chars: 0,
        };
        let chunks = chunk_segments(&segs, &cfg);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].segment_start, 0);
        assert_eq!(chunks[0].segment_end, 1);
    }
}
