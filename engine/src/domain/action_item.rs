//! An action item / task extracted from the meeting.

use serde::{Deserialize, Serialize};

use super::Evidence;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActionItem {
    pub task: String,
    /// Speaker id or resolved name of the owner, if identified.
    pub owner: Option<String>,
    /// Free-form deadline as spoken (e.g. "Friday") — normalization is a later concern.
    pub deadline: Option<String>,
    /// Where in the transcript this task was assigned.
    pub evidence: Option<Evidence>,
}
