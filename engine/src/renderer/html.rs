//! Render a [`MeetingIr`] to HTML.
//!
//! Not needed for v0. This is a defined boundary, not a hidden stub: [`render`] returns
//! [`RenderError::NotImplemented`] until an HTML target is actually required (it will likely be a
//! deterministic Markdown→HTML conversion, still no LLM).

use crate::domain::MeetingIr;

#[derive(Debug, thiserror::Error)]
pub enum RenderError {
    #[error("HTML rendering is not implemented yet")]
    NotImplemented,
}

/// Render the IR as HTML. Currently unimplemented by design.
pub fn render(_ir: &MeetingIr) -> Result<String, RenderError> {
    Err(RenderError::NotImplemented)
}
