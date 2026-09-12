//! JSON Schemas the Rust side owns and hands to the model as structured-output constraints.
//!
//! The model fills these in; it does not define them. The item schemas are shared between the
//! per-chunk **extraction** schema ([`findings_schema`]) and the final **synthesis** schema
//! ([`ir_schema`]) so the two passes stay consistent with the domain types.

use serde_json::{json, Value};

fn evidence_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "quote": { "type": "string" },
            "speaker_id": { "type": "string" },
            "start": { "type": "number" },
            "end": { "type": "number" }
        },
        "required": ["quote"]
    })
}

fn evidence_array() -> Value {
    json!({ "type": "array", "items": evidence_schema() })
}

fn topic_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "summary": { "type": "string" },
            "evidence": evidence_array()
        },
        "required": ["title"]
    })
}

fn decision_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "decision": { "type": "string" },
            "context": { "type": "string" },
            "evidence": evidence_array()
        },
        "required": ["decision"]
    })
}

fn action_item_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "description": { "type": "string" },
            "owner": { "type": ["string", "null"] },
            "deadline": { "type": ["string", "null"] },
            "status": { "type": "string", "enum": ["open", "in_progress", "done", "cancelled"] },
            "evidence": evidence_array()
        },
        "required": ["description"]
    })
}

fn open_question_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "question": { "type": "string" },
            "context": { "type": "string" },
            "evidence": evidence_array()
        },
        "required": ["question"]
    })
}

fn risk_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "description": { "type": "string" },
            "severity": { "type": "string" },
            "evidence": evidence_array()
        },
        "required": ["description"]
    })
}

/// Schema for a single chunk's findings (extraction pass): no summary/participants.
pub fn findings_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "topics": { "type": "array", "items": topic_schema() },
            "decisions": { "type": "array", "items": decision_schema() },
            "action_items": { "type": "array", "items": action_item_schema() },
            "open_questions": { "type": "array", "items": open_question_schema() },
            "risks": { "type": "array", "items": risk_schema() }
        },
        "required": ["topics", "decisions", "action_items", "open_questions", "risks"]
    })
}

/// Schema for the consolidated Meeting IR (synthesis pass).
pub fn ir_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "summary": { "type": "string" },
            "participants": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": { "type": "string" },
                        "display_name": { "type": "string" }
                    },
                    "required": ["id"]
                }
            },
            "topics": { "type": "array", "items": topic_schema() },
            "decisions": { "type": "array", "items": decision_schema() },
            "action_items": { "type": "array", "items": action_item_schema() },
            "open_questions": { "type": "array", "items": open_question_schema() },
            "risks": { "type": "array", "items": risk_schema() }
        },
        "required": ["summary", "topics", "decisions", "action_items", "open_questions", "risks"]
    })
}
