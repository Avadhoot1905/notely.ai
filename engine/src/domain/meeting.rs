//! A meeting: the top-level unit users work with.

use serde::{Deserialize, Serialize};

use super::Participant;

/// Identifies a meeting across the system.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MeetingId(pub String);

/// Metadata about a single meeting. The heavy artifacts (transcript, IR, MOM) are
/// referenced by id and stored/loaded separately.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Meeting {
    pub id: MeetingId,
    pub title: String,
    /// ISO-8601 date/time the meeting occurred, as a string to stay dependency-free.
    pub occurred_at: Option<String>,
    pub participants: Vec<Participant>,
    /// Total media duration in seconds, if known.
    pub duration_seconds: Option<f64>,
}
