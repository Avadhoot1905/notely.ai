//! An action item / task extracted from the meeting.

use serde::{Deserialize, Serialize};

use super::Evidence;

/// Lifecycle state of an action item. Defaults to [`ActionStatus::Open`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    #[default]
    Open,
    InProgress,
    Done,
    Cancelled,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ActionItem {
    /// What needs to be done.
    pub description: String,
    /// Who owns it — speaker id or resolved name, if identified.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// Deadline as spoken (e.g. "Friday"); normalization to a date is later work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deadline: Option<String>,
    #[serde(default)]
    pub status: ActionStatus,
    /// Where in the transcript this task was assigned. Each [`Evidence`] carries the `source_chunk`
    /// (`chunk_id`) and `source_timestamp` (`start`/`end`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<Evidence>,
    /// Model-reported confidence in [0,1], when available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}
