//! Chunk findings — the intermediate representation between per-chunk extraction and synthesis.
//!
//! Extraction produces one [`ChunkFindings`] per transcript chunk. Keeping this separate from the
//! final [`MeetingIr`](crate::domain::MeetingIr) is what makes long meetings, provenance, and
//! debugging tractable: findings are traceable to their source chunk before global synthesis
//! reconciles them.

use serde::{Deserialize, Serialize};

use crate::domain::{ActionItem, Decision, Evidence, OpenQuestion, Risk, Topic};

/// Structured findings extracted from a single chunk.
///
/// `chunk_id` is stamped by Rust (not the model) so provenance is authoritative.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ChunkFindings {
    #[serde(default)]
    pub chunk_id: String,
    #[serde(default)]
    pub topics: Vec<Topic>,
    #[serde(default)]
    pub decisions: Vec<Decision>,
    #[serde(default)]
    pub action_items: Vec<ActionItem>,
    #[serde(default)]
    pub open_questions: Vec<OpenQuestion>,
    #[serde(default)]
    pub risks: Vec<Risk>,
}

impl ChunkFindings {
    /// True if nothing of interest was found in this chunk.
    pub fn is_empty(&self) -> bool {
        self.topics.is_empty()
            && self.decisions.is_empty()
            && self.action_items.is_empty()
            && self.open_questions.is_empty()
            && self.risks.is_empty()
    }
}

/// All findings flattened across chunks, retaining per-item chunk-stamped evidence.
///
/// This is the deterministic input to the synthesis pass and the source of truth for provenance
/// reconciliation afterwards.
#[derive(Debug, Clone, Default)]
pub struct MergedFindings {
    pub topics: Vec<Topic>,
    pub decisions: Vec<Decision>,
    pub action_items: Vec<ActionItem>,
    pub open_questions: Vec<OpenQuestion>,
    pub risks: Vec<Risk>,
}

impl MergedFindings {
    /// Flatten all chunk findings into one set (no dedup — that's synthesis's job).
    pub fn from_chunks(findings: &[ChunkFindings]) -> Self {
        let mut merged = MergedFindings::default();
        for f in findings {
            merged.topics.extend(f.topics.iter().cloned());
            merged.decisions.extend(f.decisions.iter().cloned());
            merged.action_items.extend(f.action_items.iter().cloned());
            merged
                .open_questions
                .extend(f.open_questions.iter().cloned());
            merged.risks.extend(f.risks.iter().cloned());
        }
        merged
    }

    pub fn is_empty(&self) -> bool {
        self.topics.is_empty()
            && self.decisions.is_empty()
            && self.action_items.is_empty()
            && self.open_questions.is_empty()
            && self.risks.is_empty()
    }

    /// All distinct evidence quotes across findings — used to guard against invented owners.
    pub fn all_evidence(&self) -> Vec<&Evidence> {
        let mut out: Vec<&Evidence> = Vec::new();
        for d in &self.decisions {
            out.extend(d.evidence.iter());
        }
        for a in &self.action_items {
            out.extend(a.evidence.iter());
        }
        for t in &self.topics {
            out.extend(t.evidence.iter());
        }
        for q in &self.open_questions {
            out.extend(q.evidence.iter());
        }
        for r in &self.risks {
            out.extend(r.evidence.iter());
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_flattens_across_chunks() {
        let f1 = ChunkFindings {
            chunk_id: "chunk-0".into(),
            decisions: vec![Decision {
                decision: "a".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let f2 = ChunkFindings {
            chunk_id: "chunk-1".into(),
            action_items: vec![ActionItem {
                description: "b".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let merged = MergedFindings::from_chunks(&[f1, f2]);
        assert_eq!(merged.decisions.len(), 1);
        assert_eq!(merged.action_items.len(), 1);
        assert!(!merged.is_empty());
    }
}
