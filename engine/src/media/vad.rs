//! Voice-activity detection boundary.
//!
//! VAD splits audio into speech regions so ASR can skip silence and long meetings can be chunked.
//! The concrete algorithm isn't selected yet, so v0 ships a clean trait plus a [`NoopVad`] that
//! treats the whole clip as a single speech segment — honest and deterministic, not a fake VAD.

/// A detected region of speech, in seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpeechSegment {
    pub start: f64,
    pub end: f64,
}

/// Splits an audio duration into speech segments.
pub trait Vad: Send + Sync {
    fn segments(&self, duration_seconds: f64) -> Vec<SpeechSegment>;
}

/// Treats the entire clip as one speech segment. Placeholder until a real VAD is chosen.
#[derive(Default)]
pub struct NoopVad;

impl Vad for NoopVad {
    fn segments(&self, duration_seconds: f64) -> Vec<SpeechSegment> {
        if duration_seconds <= 0.0 {
            Vec::new()
        } else {
            vec![SpeechSegment {
                start: 0.0,
                end: duration_seconds,
            }]
        }
    }
}
