//! Synthesis: deterministic assembly/normalization of the extracted IR.
//!
//! This is NOT another LLM call. It cleans up and completes what extraction produced: fills in
//! participants observed in the transcript, applies known context (title is metadata, not IR),
//! and trims whitespace. Keeping this deterministic means the same extraction always yields the
//! same assembled IR.

use crate::domain::{MeetingIr, Participant, Transcript};

use super::provider::AnalysisContext;

/// Normalize and complete an extracted IR against the transcript and context.
pub fn synthesize(
    mut ir: MeetingIr,
    transcript: &Transcript,
    _context: &AnalysisContext,
) -> MeetingIr {
    ir.summary = ir.summary.trim().to_string();

    // Ensure every speaker seen in the transcript is represented, without dropping any
    // display-name resolution the model already provided.
    for speaker in transcript.speaker_ids() {
        if !ir.participants.iter().any(|p| p.id == speaker) {
            ir.participants.push(Participant::new(speaker));
        }
    }

    ir
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::TranscriptSegment;

    fn seg(speaker: &str, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            speaker_id: Some(speaker.to_string()),
            start: 0.0,
            end: 1.0,
            text: text.to_string(),
            language: None,
        }
    }

    #[test]
    fn backfills_participants_from_transcript() {
        let transcript = Transcript {
            segments: vec![seg("S1", "hi"), seg("S2", "yo")],
        };
        let ir = synthesize(
            MeetingIr::default(),
            &transcript,
            &AnalysisContext::default(),
        );
        let ids: Vec<_> = ir.participants.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, vec!["S1", "S2"]);
    }

    #[test]
    fn preserves_existing_participant_names() {
        let transcript = Transcript {
            segments: vec![seg("S1", "hi")],
        };
        let ir = MeetingIr {
            participants: vec![Participant {
                id: "S1".into(),
                display_name: Some("Avi".into()),
            }],
            ..Default::default()
        };
        let out = synthesize(ir, &transcript, &AnalysisContext::default());
        assert_eq!(out.participants.len(), 1);
        assert_eq!(out.participants[0].display_name.as_deref(), Some("Avi"));
    }
}
