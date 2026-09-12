//! Deterministic rendering of a [`MeetingIr`](crate::domain::MeetingIr) into output formats.
//!
//! This is template-driven and fully deterministic — an LLM is NEVER used merely to format
//! Markdown/HTML/JSON. Given the same IR, the same bytes come out every time.

pub mod html;
pub mod json;
pub mod markdown;
