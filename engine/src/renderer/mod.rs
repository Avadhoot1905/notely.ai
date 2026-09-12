//! Deterministic rendering of a [`crate::domain::MeetingIr`] into output formats.
//!
//! Template-driven and fully deterministic — an LLM is NEVER used to format Markdown/HTML/JSON.
//! Given the same IR, the same bytes come out every time.

pub mod html;
pub mod json;
pub mod markdown;
