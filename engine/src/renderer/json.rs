//! Render a [`MeetingIr`](crate::domain::MeetingIr) to canonical JSON.
//!
//! This is the machine-readable output other tools/integrations consume. It is a direct,
//! stable serialization of the IR — no LLM involved.

use crate::domain::MeetingIr;

/// Serialize the IR to pretty JSON.
pub fn render(ir: &MeetingIr) -> anyhow::Result<String> {
    Ok(serde_json::to_string_pretty(ir)?)
}
