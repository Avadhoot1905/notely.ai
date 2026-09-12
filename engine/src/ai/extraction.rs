//! Extraction pass: turn ONE transcript chunk into structured [`ChunkFindings`] via a single,
//! schema-constrained LLM call.
//!
//! The Rust side owns the schema (see [`crate::ai::schema`]) — the model fills it in. Output is
//! deserialized into domain types; malformed output is an error, never silently accepted. After
//! parsing, Rust stamps each item's evidence with the chunk's provenance (`chunk_id`, timestamps)
//! so findings are always traceable to the source transcript.

use crate::domain::Evidence;
use crate::llm::GenerateRequest;
use crate::preprocess::Chunk;

use super::findings::ChunkFindings;
use super::provider::{AiError, AnalysisContext};
use super::schema;

/// System prompt: constrain the model to faithful, structured extraction — no prose, no invention.
pub fn system_prompt() -> String {
    "You are Notely's meeting extraction engine. You read ONE excerpt of a meeting transcript and \
     extract structured findings. Respond ONLY with a single JSON object matching the provided \
     schema. Do not write Markdown, prose, or commentary. Extract only what is explicitly \
     supported by THIS excerpt; do not infer or invent. For each decision, action item, topic, \
     question, and risk, include a short supporting `quote` copied verbatim from the excerpt. For \
     action items, set `deadline` when a time is explicitly stated (e.g. \"by Thursday\", \"next \
     Monday\") and `owner` when a person is explicitly named; otherwise use null — never guess. If \
     the excerpt contains nothing for a category, return an empty array."
        .to_string()
}

/// Build the extraction prompt for a chunk (primary text framed by neighbor context).
pub fn build_prompt(chunk: &Chunk, context: &AnalysisContext) -> String {
    let mut prompt = String::new();
    if let Some(title) = &context.title {
        prompt.push_str(&format!("Meeting title: {title}\n\n"));
    }
    prompt.push_str(&format!("Transcript excerpt ({}):\n", chunk.id));
    prompt.push_str(&chunk.prompt_text());
    prompt.push_str(
        "\n\nExtract the structured findings for THIS excerpt as JSON. Use empty arrays where \
         there is nothing. Do not invent owners or deadlines.",
    );
    prompt
}

/// Assemble the schema-constrained extraction request for one chunk.
pub fn build_request(chunk: &Chunk, context: &AnalysisContext) -> GenerateRequest {
    GenerateRequest::new(build_prompt(chunk, context))
        .with_system(system_prompt())
        .with_format(schema::findings_schema())
        // Low temperature: extraction should be faithful, not creative.
        .with_temperature(0.1)
}

/// Parse the model's raw text into [`ChunkFindings`], then deterministically stamp + ground
/// provenance against the chunk's real transcript segments.
pub fn parse_findings(raw: &str, chunk: &Chunk) -> Result<ChunkFindings, AiError> {
    let trimmed = strip_to_json_object(raw);
    let mut findings: ChunkFindings =
        serde_json::from_str(trimmed).map_err(|e| AiError::Parse(e.to_string()))?;
    stamp_provenance(&mut findings, chunk);
    Ok(findings)
}

/// Ground every finding's evidence in the source transcript. Small models often omit the evidence
/// quote; rather than trust them to copy it, Rust matches each item's text to the best transcript
/// segment in the chunk and attaches that segment's real quote + timestamp + speaker. This gives
/// reliable provenance deterministically. Quotes the model DID copy are kept and just back-stamped.
fn stamp_provenance(findings: &mut ChunkFindings, chunk: &Chunk) {
    findings.chunk_id = chunk.id.clone();
    for d in &mut findings.decisions {
        ground(&mut d.evidence, &d.decision, chunk);
    }
    for a in &mut findings.action_items {
        ground(&mut a.evidence, &a.description, chunk);
    }
    for t in &mut findings.topics {
        ground(&mut t.evidence, &t.title, chunk);
    }
    for q in &mut findings.open_questions {
        ground(&mut q.evidence, &q.question, chunk);
    }
    for r in &mut findings.risks {
        ground(&mut r.evidence, &r.description, chunk);
    }
}

/// Attach/repair evidence for one item given its descriptive text.
fn ground(evidence: &mut Vec<Evidence>, item_text: &str, chunk: &Chunk) {
    let has_real_quote = evidence.iter().any(|e| !e.quote.trim().is_empty());
    if has_real_quote {
        // Keep the model's quotes; just fill missing provenance.
        for ev in evidence.iter_mut() {
            ev.chunk_id.get_or_insert_with(|| chunk.id.clone());
            if ev.start.is_none() {
                ev.start = Some(chunk.start);
            }
            if ev.end.is_none() {
                ev.end = Some(chunk.end);
            }
        }
        return;
    }

    // No usable quote from the model → ground against the best-matching segment.
    match best_segment(item_text, chunk) {
        Some(ev) => *evidence = vec![ev],
        None => {
            // Nothing matched: keep a provenance-only marker (chunk range), no fabricated text.
            *evidence = vec![Evidence {
                quote: String::new(),
                speaker_id: None,
                start: Some(chunk.start),
                end: Some(chunk.end),
                chunk_id: Some(chunk.id.clone()),
            }];
        }
    }
}

/// Find the transcript segment in the chunk that best overlaps `item_text` (by shared words) and
/// return it as an [`Evidence`]. Deterministic; returns `None` if nothing meaningfully overlaps.
fn best_segment(item_text: &str, chunk: &Chunk) -> Option<Evidence> {
    let needle = word_set(item_text);
    if needle.is_empty() {
        return None;
    }
    let mut best: Option<(usize, &crate::domain::TranscriptSegment)> = None;
    for seg in &chunk.segments {
        let overlap = word_set(&seg.text).intersection(&needle).count();
        if overlap == 0 {
            continue;
        }
        if best.map(|(b, _)| overlap > b).unwrap_or(true) {
            best = Some((overlap, seg));
        }
    }
    best.map(|(_, seg)| Evidence {
        quote: seg.text.clone(),
        speaker_id: seg.speaker_id.clone(),
        start: Some(seg.start),
        end: Some(seg.end),
        chunk_id: Some(chunk.id.clone()),
    })
}

fn word_set(s: &str) -> std::collections::BTreeSet<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() > 2) // ignore tiny stopword-ish tokens
        .map(|w| w.to_string())
        .collect()
}

/// Defensive: extract the outermost `{...}` object if the model wrapped JSON in prose/fences.
pub fn strip_to_json_object(raw: &str) -> &str {
    let start = raw.find('{');
    let end = raw.rfind('}');
    match (start, end) {
        (Some(s), Some(e)) if e >= s => &raw[s..=e],
        _ => raw.trim(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ChunkingConfig;
    use crate::domain::TranscriptSegment;
    use crate::preprocess::chunk_segments;

    fn one_chunk() -> Chunk {
        let segs = vec![TranscriptSegment {
            speaker_id: Some("S1".into()),
            start: 10.0,
            end: 20.0,
            text: "we will ship friday".into(),
            language: None,
            confidence: None,
        }];
        chunk_segments(&segs, &ChunkingConfig::default()).remove(0)
    }

    #[test]
    fn parses_and_stamps_chunk_provenance_on_evidence() {
        let raw = r#"{"topics":[],"decisions":[{"decision":"ship friday",
            "evidence":[{"quote":"we will ship friday"}]}],
            "action_items":[],"open_questions":[],"risks":[]}"#;
        let f = parse_findings(raw, &one_chunk()).unwrap();
        assert_eq!(f.chunk_id, "chunk-0");
        let ev = &f.decisions[0].evidence[0];
        assert_eq!(ev.chunk_id.as_deref(), Some("chunk-0"));
        assert_eq!(ev.start, Some(10.0)); // filled from chunk
    }

    #[test]
    fn item_without_evidence_gets_provenance_marker() {
        let raw = r#"{"topics":[],"decisions":[],
            "action_items":[{"description":"do the thing"}],
            "open_questions":[],"risks":[]}"#;
        let f = parse_findings(raw, &one_chunk()).unwrap();
        let ev = &f.action_items[0].evidence;
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].chunk_id.as_deref(), Some("chunk-0"));
        assert!(ev[0].quote.is_empty(), "no quote fabricated");
    }

    #[test]
    fn rejects_non_json() {
        assert!(parse_findings("sorry, cannot", &one_chunk()).is_err());
    }
}
