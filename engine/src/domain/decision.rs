//! A decision reached during the meeting.

use serde::{Deserialize, Serialize};

use super::Evidence;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Decision {
    pub summary: String,
    /// Where in the transcript this decision was made — for traceability in the UI.
    pub evidence: Option<Evidence>,
}
