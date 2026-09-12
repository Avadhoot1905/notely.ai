//! A meeting participant / speaker.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    /// Stable speaker id (e.g. a diarization label like "S1") — not necessarily a person's name.
    pub id: String,
    /// Human-readable display name, once known/resolved.
    pub display_name: Option<String>,
}
