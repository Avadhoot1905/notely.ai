//! Meeting IR (Intermediate Representation) — the central abstraction of Notely.
//!
//! The LLM produces this STRUCTURED representation, not the final prose MOM. The IR is the
//! stable contract between the reasoning layer (`ai`) and everything that consumes meeting
//! intelligence (`renderer`, `storage`, future integrations). Rendering the IR to
//! Markdown/HTML/JSON is deterministic and template-driven — never an LLM formatting pass.
//!
//! The Rust side owns this schema. The LLM is asked to fill it in; it does not get to define it.

use serde::{Deserialize, Serialize};

use super::{ActionItem, Decision, Participant};

/// A pointer back into the meeting so a generated claim is traceable.
///
/// Evidence is what makes the MOM verifiable: every decision/action/etc. can carry the quote it
/// came from and, when timestamps are available, the transcript time span.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Evidence {
    /// The supporting quote from the transcript.
    pub quote: String,
    /// Speaker id (matching a [`Participant::id`]) who said it, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speaker_id: Option<String>,
    /// Start time in seconds within the source media, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<f64>,
    /// End time in seconds within the source media, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<f64>,
}

/// A discussion topic and its gist.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Topic {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<Evidence>,
}

/// A question raised but left unresolved.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct OpenQuestion {
    pub question: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<Evidence>,
}

/// A risk or concern surfaced during the meeting.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Risk {
    pub description: String,
    /// Free-form severity as judged (e.g. "low"/"medium"/"high") — normalization is later work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<Evidence>,
}

/// Structured understanding of one meeting: the thing worth getting right.
///
/// Field order here is also the canonical section order used by the Markdown renderer.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct MeetingIr {
    /// Short, neutral overview of the meeting.
    pub summary: String,
    #[serde(default)]
    pub participants: Vec<Participant>,
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
