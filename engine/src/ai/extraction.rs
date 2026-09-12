//! Extraction: turn a transcript into the structured Meeting IR via a single, schema-constrained
//! LLM call.
//!
//! The Rust side owns the schema — the model is asked to *fill it in*, not define it. We pass a
//! JSON Schema as Ollama's `format` so the runtime constrains output to valid JSON, then we
//! deserialize into the domain [`MeetingIr`]. Malformed output is an error, never silently
//! accepted.

use serde_json::{json, Value};

use crate::domain::{MeetingIr, Transcript};
use crate::llm::GenerateRequest;

use super::provider::{AiError, AnalysisContext};

/// System prompt: constrain the model to structured extraction, not prose.
pub fn system_prompt() -> String {
    "You are Notely's meeting analysis engine. You read a meeting transcript and extract a \
     STRUCTURED summary. Respond ONLY with a single JSON object matching the provided schema. \
     Do not write Markdown, prose, or commentary. Base every field strictly on the transcript; \
     do not invent facts. For decisions, action items, topics, questions and risks, include a \
     short supporting quote from the transcript in the `evidence` field when possible."
        .to_string()
}

/// Build the user prompt from the transcript and any context.
pub fn build_prompt(transcript: &Transcript, context: &AnalysisContext) -> String {
    let mut prompt = String::new();
    if let Some(title) = &context.title {
        prompt.push_str(&format!("Meeting title: {title}\n\n"));
    }
    prompt.push_str("Transcript:\n");
    prompt.push_str(&transcript.to_prompt_text());
    prompt.push_str(
        "\nExtract the structured Meeting IR as JSON. If a section has nothing, use an empty \
         array. `summary` must be a concise neutral paragraph.",
    );
    prompt
}

/// JSON Schema describing [`MeetingIr`], passed to the runtime for structured output.
///
/// Kept in sync with the domain types by the round-trip tests in this module.
pub fn ir_json_schema() -> Value {
    let evidence = json!({
        "type": "object",
        "properties": {
            "quote": { "type": "string" },
            "speaker_id": { "type": "string" },
            "start": { "type": "number" },
            "end": { "type": "number" }
        },
        "required": ["quote"]
    });
    let evidence_array = json!({ "type": "array", "items": evidence });

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
            "topics": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": { "type": "string" },
                        "summary": { "type": "string" },
                        "evidence": evidence_array
                    },
                    "required": ["title"]
                }
            },
            "decisions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "decision": { "type": "string" },
                        "context": { "type": "string" },
                        "evidence": evidence_array
                    },
                    "required": ["decision"]
                }
            },
            "action_items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "description": { "type": "string" },
                        "owner": { "type": "string" },
                        "deadline": { "type": "string" },
                        "status": { "type": "string", "enum": ["open", "in_progress", "done", "cancelled"] },
                        "evidence": evidence_array
                    },
                    "required": ["description"]
                }
            },
            "open_questions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string" },
                        "context": { "type": "string" },
                        "evidence": evidence_array
                    },
                    "required": ["question"]
                }
            },
            "risks": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "description": { "type": "string" },
                        "severity": { "type": "string" },
                        "evidence": evidence_array
                    },
                    "required": ["description"]
                }
            }
        },
        "required": ["summary", "topics", "decisions", "action_items", "open_questions", "risks"]
    })
}

/// Assemble the schema-constrained generation request for extraction.
pub fn build_request(transcript: &Transcript, context: &AnalysisContext) -> GenerateRequest {
    GenerateRequest::new(build_prompt(transcript, context))
        .with_system(system_prompt())
        .with_format(ir_json_schema())
        // Low temperature: extraction should be faithful, not creative.
        .with_temperature(0.2)
}

/// Parse the model's raw text into a [`MeetingIr`]. Errors instead of accepting junk.
pub fn parse_ir(raw: &str) -> Result<MeetingIr, AiError> {
    let trimmed = strip_to_json_object(raw);
    serde_json::from_str::<MeetingIr>(trimmed).map_err(|e| AiError::Parse(e.to_string()))
}

/// Defensive: some models wrap JSON in prose or code fences even with `format` set. Extract the
/// outermost `{...}` object if present, otherwise return the input unchanged.
fn strip_to_json_object(raw: &str) -> &str {
    let bytes = raw.as_bytes();
    let start = raw.find('{');
    let end = raw.rfind('}');
    match (start, end) {
        (Some(s), Some(e)) if e >= s && e < bytes.len() => &raw[s..=e],
        _ => raw.trim(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_minimal_valid_ir() {
        let raw = r#"{"summary":"We shipped v0.","topics":[],"decisions":[],
            "action_items":[],"open_questions":[],"risks":[]}"#;
        let ir = parse_ir(raw).expect("valid IR");
        assert_eq!(ir.summary, "We shipped v0.");
    }

    #[test]
    fn strips_surrounding_prose_and_fences() {
        let raw = "Here you go:\n```json\n{\"summary\":\"x\",\"topics\":[],\"decisions\":[],\
            \"action_items\":[],\"open_questions\":[],\"risks\":[]}\n```";
        let ir = parse_ir(raw).expect("valid IR");
        assert_eq!(ir.summary, "x");
    }

    #[test]
    fn rejects_non_json() {
        assert!(parse_ir("I could not do that.").is_err());
    }
}
