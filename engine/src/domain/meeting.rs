//! A meeting: the top-level unit users work with.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::Participant;

/// Identifies a meeting across the system.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MeetingId(pub String);

impl MeetingId {
    /// Generate a fresh random meeting id.
    pub fn new() -> Self {
        MeetingId(Uuid::new_v4().to_string())
    }
}

impl Default for MeetingId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for MeetingId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Metadata about a single meeting. Heavy artifacts (transcript, IR, MOM) are referenced by id
/// and stored separately.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Meeting {
    pub id: MeetingId,
    pub title: String,
    /// When the record was created.
    pub created_at: DateTime<Utc>,
    /// When the meeting actually occurred, if known/different.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub occurred_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub participants: Vec<Participant>,
    /// Total media duration in seconds, if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
}

impl Meeting {
    /// Create a new meeting with a fresh id and `created_at = now`.
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            id: MeetingId::new(),
            title: title.into(),
            created_at: Utc::now(),
            occurred_at: None,
            participants: Vec::new(),
            duration_seconds: None,
        }
    }
}
