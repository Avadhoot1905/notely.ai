//! A meeting participant / speaker.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    /// Stable speaker id (e.g. a diarization label like "S1") — not necessarily a person's name.
    pub id: String,
    /// Human-readable display name, once known/resolved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
}

impl Participant {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: None,
        }
    }
}
