//! Meeting IR (Intermediate Representation) — the central abstraction of Notely.
//!
//! The LLM produces this STRUCTURED representation, not the final prose MOM. The IR is
//! the stable contract between the reasoning layer (`ai`) and everything that consumes
//! meeting intelligence (`renderer`, storage, future integrations). Rendering the IR to
//! Markdown/HTML/JSON is deterministic and template-driven — never an LLM formatting pass.
//!
//! See `docs/meeting-ir.md` for the rationale.

use serde::{Deserialize, Serialize};

use super::{ActionItem, Decision, Participant};

/// Structured understanding of one meeting. Fields are intentionally simple for v0 and
/// will grow (topics, questions, risks, timeline) as the schema stabilizes.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MeetingIr {
    pub title: Option<String>,
    /// Short neutral overview of the meeting.
    pub summary: Option<String>,
    pub participants: Vec<Participant>,
    pub decisions: Vec<Decision>,
    pub action_items: Vec<ActionItem>,
    // TODO(v0+): topics, questions, risks, timeline — add once extraction supports them.
}
