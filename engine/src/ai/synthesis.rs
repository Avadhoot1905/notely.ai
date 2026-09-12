//! Synthesis pass: consolidate per-chunk [`ChunkFindings`] into one coherent [`MeetingIr`].
//!
//! This is a real second LLM pass (dedup/consolidate/summarize) followed by DETERMINISTIC
//! reconciliation in Rust:
//!   - evidence/provenance is re-attached from the extraction findings (the authoritative source),
//!     not trusted from the synthesis model;
//!   - owners/deadlines the model added that are not supported by the findings or the transcript
//!     are dropped (set to null) — the model may not invent them;
//!   - participants are backfilled from the transcript speakers.

use std::collections::BTreeSet;

use crate::domain::{Evidence, MeetingIr, Participant, Transcript};
use crate::llm::GenerateRequest;

use super::findings::MergedFindings;
use super::provider::{AiError, AnalysisContext};
use super::schema;

/// System prompt for the consolidation pass.
pub fn system_prompt() -> String {
    "You are Notely's meeting synthesis engine. You are given structured findings already \
     extracted from a meeting transcript. Consolidate them into a single coherent Meeting IR: \
     merge duplicates, group related items, and write a concise, neutral overall `summary`. \
     Respond ONLY with a single JSON object matching the schema. Do not add information that is \
     not present in the findings. Keep supporting `quote`s from the findings. If an action item's \
     owner or deadline is not stated in the findings, use null — never guess."
        .to_string()
}

/// Build the synthesis prompt from the merged findings.
pub fn build_prompt(merged: &MergedFindings, context: &AnalysisContext) -> String {
    let findings_json = serde_json::to_string_pretty(&serde_json::json!({
        "topics": merged.topics,
        "decisions": merged.decisions,
        "action_items": merged.action_items,
        "open_questions": merged.open_questions,
        "risks": merged.risks,
    }))
    .unwrap_or_else(|_| "{}".to_string());

    let mut prompt = String::new();
    if let Some(title) = &context.title {
        prompt.push_str(&format!("Meeting title: {title}\n\n"));
    }
    prompt.push_str("Findings extracted from the transcript (source of truth):\n");
    prompt.push_str(&findings_json);
    prompt.push_str(
        "\n\nConsolidate these into the Meeting IR JSON. Merge duplicate decisions/action items/\
         topics. Write a concise neutral `summary`. Do not invent owners or deadlines; use null \
         when unknown.",
    );
    prompt
}

/// Assemble the schema-constrained synthesis request.
pub fn build_request(merged: &MergedFindings, context: &AnalysisContext) -> GenerateRequest {
    GenerateRequest::new(build_prompt(merged, context))
        .with_system(system_prompt())
        .with_format(schema::ir_schema())
        .with_temperature(0.3)
}

/// Parse the model's raw text into a [`MeetingIr`].
pub fn parse_ir(raw: &str) -> Result<MeetingIr, AiError> {
    let trimmed = super::extraction::strip_to_json_object(raw);
    serde_json::from_str::<MeetingIr>(trimmed).map_err(|e| AiError::Parse(e.to_string()))
}

/// Deterministically reconcile a synthesized IR against the authoritative findings + transcript.
pub fn reconcile(mut ir: MeetingIr, merged: &MergedFindings, transcript: &Transcript) -> MeetingIr {
    ir.summary = ir.summary.trim().to_string();

    // Backfill participants from the transcript speakers (keep any names the model resolved).
    for speaker in transcript.speaker_ids() {
        if !ir.participants.iter().any(|p| p.id == speaker) {
            ir.participants.push(Participant::new(speaker));
        }
    }

    let transcript_lower = transcript
        .segments
        .iter()
        .map(|s| s.text.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ");

    // Re-attach evidence/provenance from the findings for each consolidated item.
    for d in &mut ir.decisions {
        let ev = matched_evidence(
            &d.decision,
            merged.decisions.iter().map(|x| (&x.decision, &x.evidence)),
        );
        attach(&mut d.evidence, ev);
    }
    for t in &mut ir.topics {
        let ev = matched_evidence(
            &t.title,
            merged.topics.iter().map(|x| (&x.title, &x.evidence)),
        );
        attach(&mut t.evidence, ev);
    }
    for q in &mut ir.open_questions {
        let ev = matched_evidence(
            &q.question,
            merged
                .open_questions
                .iter()
                .map(|x| (&x.question, &x.evidence)),
        );
        attach(&mut q.evidence, ev);
    }
    for r in &mut ir.risks {
        let ev = matched_evidence(
            &r.description,
            merged.risks.iter().map(|x| (&x.description, &x.evidence)),
        );
        attach(&mut r.evidence, ev);
    }
    for a in &mut ir.action_items {
        let sources: Vec<&crate::domain::ActionItem> = merged
            .action_items
            .iter()
            .filter(|s| similar(&a.description, &s.description))
            .collect();

        // Evidence from matched sources.
        let mut ev: Vec<Evidence> = Vec::new();
        for s in &sources {
            ev.extend(s.evidence.iter().cloned());
        }
        attach(&mut a.evidence, ev);

        // Resolve owner/deadline: prefer what synthesis produced, else recover from a matched
        // extraction finding (that IS supported by evidence). Then guard against invention.
        let finding_owner = sources.iter().find_map(|s| s.owner.clone());
        let finding_deadline = sources.iter().find_map(|s| s.deadline.clone());

        // Owner guard: keep only if a source finding stated it or it appears in the transcript.
        a.owner = guard_field(
            a.owner.take().or(finding_owner),
            &sources,
            |s| s.owner.as_deref(),
            &transcript_lower,
        );
        // Deadline guard: same rule.
        a.deadline = guard_field(
            a.deadline.take().or(finding_deadline),
            &sources,
            |s| s.deadline.as_deref(),
            &transcript_lower,
        );
    }

    ir
}

/// Keep `value` only if some source finding carried the same field, or the value appears verbatim
/// in the transcript. Otherwise drop it (the synthesis model may not invent owners/deadlines).
fn guard_field<T>(
    value: Option<String>,
    sources: &[&T],
    field_of: impl Fn(&T) -> Option<&str>,
    transcript_lower: &str,
) -> Option<String> {
    let value = value?;
    let v = value.trim();
    if v.is_empty() {
        return None;
    }
    let vl = v.to_lowercase();
    let from_source = sources.iter().any(|s| {
        field_of(s)
            .map(|f| f.trim().eq_ignore_ascii_case(v))
            .unwrap_or(false)
    });
    if from_source || transcript_lower.contains(&vl) {
        Some(value)
    } else {
        None
    }
}

/// Collect evidence from source items whose text is similar to `needle`.
fn matched_evidence<'a>(
    needle: &str,
    sources: impl Iterator<Item = (&'a String, &'a Vec<Evidence>)>,
) -> Vec<Evidence> {
    let mut out = Vec::new();
    for (text, evidence) in sources {
        if similar(needle, text) {
            out.extend(evidence.iter().cloned());
        }
    }
    out
}

/// Replace `target` evidence with `found` when we have provenance from the findings; otherwise keep
/// whatever the item already had. Deduplicates by (quote, chunk_id).
fn attach(target: &mut Vec<Evidence>, found: Vec<Evidence>) {
    if found.is_empty() {
        return;
    }
    let mut seen = BTreeSet::new();
    let mut deduped = Vec::new();
    for ev in found {
        let key = (ev.quote.clone(), ev.chunk_id.clone().unwrap_or_default());
        if seen.insert(key) {
            deduped.push(ev);
        }
    }
    *target = deduped;
}

/// Deterministic text similarity: containment or word-set Jaccard ≥ 0.34.
fn similar(a: &str, b: &str) -> bool {
    let na = normalize(a);
    let nb = normalize(b);
    if na.is_empty() || nb.is_empty() {
        return false;
    }
    if na.contains(&nb) || nb.contains(&na) {
        return true;
    }
    let sa: BTreeSet<&str> = na.split(' ').collect();
    let sb: BTreeSet<&str> = nb.split(' ').collect();
    let inter = sa.intersection(&sb).count();
    let union = sa.union(&sb).count().max(1);
    (inter as f64 / union as f64) >= 0.34
}

fn normalize(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{ActionItem, Decision, MeetingIr, TranscriptSegment};

    fn transcript() -> Transcript {
        Transcript {
            segments: vec![TranscriptSegment {
                speaker_id: Some("S1".into()),
                start: 0.0,
                end: 5.0,
                text: "Avi will do the migration by friday".into(),
                language: None,
                confidence: None,
            }],
        }
    }

    #[test]
    fn reconcile_reattaches_evidence_from_findings() {
        let merged = MergedFindings {
            decisions: vec![Decision {
                decision: "ship the migration".into(),
                evidence: vec![Evidence {
                    quote: "we ship the migration".into(),
                    chunk_id: Some("chunk-0".into()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };
        let ir = MeetingIr {
            summary: "s".into(),
            decisions: vec![Decision {
                decision: "Ship the migration".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let out = reconcile(ir, &merged, &transcript());
        assert_eq!(
            out.decisions[0].evidence[0].chunk_id.as_deref(),
            Some("chunk-0")
        );
    }

    #[test]
    fn drops_invented_owner_but_keeps_supported_one() {
        let merged = MergedFindings {
            action_items: vec![ActionItem {
                description: "do the migration".into(),
                owner: None,
                ..Default::default()
            }],
            ..Default::default()
        };
        // Model invented "Bob" (not in transcript/findings) -> dropped. "Avi" is in transcript -> kept.
        let ir = MeetingIr {
            summary: "s".into(),
            action_items: vec![ActionItem {
                description: "do the migration".into(),
                owner: Some("Bob".into()),
                deadline: Some("friday".into()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let out = reconcile(ir, &merged, &transcript());
        assert_eq!(out.action_items[0].owner, None, "invented owner dropped");
        assert_eq!(
            out.action_items[0].deadline.as_deref(),
            Some("friday"),
            "deadline in transcript kept"
        );
    }

    #[test]
    fn backfills_participants() {
        let ir = MeetingIr {
            summary: "s".into(),
            ..Default::default()
        };
        let out = reconcile(ir, &MergedFindings::default(), &transcript());
        assert_eq!(out.participants[0].id, "S1");
    }
}
