//! Render a [`MeetingIr`](crate::domain::MeetingIr) to a Markdown MOM document.
//!
//! Deterministic templating only. TODO(v0): implement section templates (summary, decisions,
//! action items, participants) with evidence links back into the transcript.

use crate::domain::MeetingIr;

/// Render the IR as a Markdown string.
pub fn render(_ir: &MeetingIr) -> String {
    // TODO(v0): real templates.
    String::new()
}
