//! Render a [`MeetingIr`](crate::domain::MeetingIr) to an HTML MOM document.
//!
//! Deterministic templating only. TODO(v0): implement, likely by generating Markdown and
//! converting, or via dedicated HTML templates.

use crate::domain::MeetingIr;

/// Render the IR as an HTML string.
pub fn render(_ir: &MeetingIr) -> String {
    // TODO(v0): real templates.
    String::new()
}
