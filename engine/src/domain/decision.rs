//! A decision reached during the meeting.

use serde::{Deserialize, Serialize};

use super::Evidence;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Decision {
    /// The decision itself, stated plainly.
    pub decision: String,
    /// Why it was made / surrounding context, if captured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    /// Supporting quotes/timestamps from the transcript. Each [`Evidence`] carries the
    /// `source_chunk` (`chunk_id`) and `source_timestamp` (`start`/`end`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<Evidence>,
    /// Model-reported confidence in [0,1], when available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}
