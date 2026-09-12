//! Serialization / deserialization round-trips for the core domain types.

use notely_engine::domain::{
    ActionItem, ActionStatus, Decision, Evidence, Meeting, MeetingIr, OpenQuestion, Participant,
    Risk, Topic, Transcript, TranscriptSegment,
};

#[test]
fn meeting_round_trips() {
    let mut m = Meeting::new("Weekly sync");
    m.participants.push(Participant {
        id: "S1".into(),
        display_name: Some("Avi".into()),
    });
    m.duration_seconds = Some(95.0);

    let json = serde_json::to_string(&m).unwrap();
    let back: Meeting = serde_json::from_str(&json).unwrap();
    assert_eq!(m, back);
}

#[test]
fn transcript_round_trips_and_optional_fields_omitted() {
    let t = Transcript {
        segments: vec![TranscriptSegment {
            speaker_id: Some("S1".into()),
            start: 0.0,
            end: 1.0,
            text: "hi".into(),
            language: None,
        }],
    };
    let json = serde_json::to_string(&t).unwrap();
    // `language: None` should be skipped, not serialized as null.
    assert!(!json.contains("language"));
    let back: Transcript = serde_json::from_str(&json).unwrap();
    assert_eq!(t, back);
}

#[test]
fn meeting_ir_round_trips_with_all_sections() {
    let ir = MeetingIr {
        summary: "We planned v0.".into(),
        participants: vec![Participant::new("S1")],
        topics: vec![Topic {
            title: "Scope".into(),
            summary: Some("v0".into()),
            evidence: vec![],
        }],
        decisions: vec![Decision {
            decision: "Ship transcript path first".into(),
            context: Some("core bet".into()),
            evidence: vec![Evidence {
                quote: "that's the whole bet".into(),
                ..Default::default()
            }],
        }],
        action_items: vec![ActionItem {
            description: "Wire health check".into(),
            owner: Some("S2".into()),
            deadline: Some("Friday".into()),
            status: ActionStatus::InProgress,
            evidence: vec![],
        }],
        open_questions: vec![OpenQuestion {
            question: "Which Qwen size?".into(),
            context: None,
            evidence: vec![],
        }],
        risks: vec![Risk {
            description: "Ollama may be down".into(),
            severity: Some("medium".into()),
            evidence: vec![],
        }],
    };

    let json = serde_json::to_string_pretty(&ir).unwrap();
    let back: MeetingIr = serde_json::from_str(&json).unwrap();
    assert_eq!(ir, back);
}

#[test]
fn action_status_serializes_snake_case() {
    let json = serde_json::to_string(&ActionStatus::InProgress).unwrap();
    assert_eq!(json, "\"in_progress\"");
    let back: ActionStatus = serde_json::from_str("\"done\"").unwrap();
    assert_eq!(back, ActionStatus::Done);
}

#[test]
fn meeting_ir_accepts_extra_defaults_from_partial_json() {
    // Model output that only fills summary + a decision must still deserialize (empty arrays).
    let json = r#"{"summary":"s","decisions":[{"decision":"d"}]}"#;
    let ir: MeetingIr = serde_json::from_str(json).unwrap();
    assert_eq!(ir.summary, "s");
    assert_eq!(ir.decisions.len(), 1);
    assert!(ir.action_items.is_empty());
}
