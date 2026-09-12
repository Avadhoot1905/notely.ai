//! Application concepts only — the portable core of Notely.
//!
//! Types here describe *what a meeting is*, not how it is captured, processed, stored,
//! or displayed. They MUST NOT know about Flutter, IPC, FFmpeg, Whisper, Qwen, Ollama,
//! SQLite, or filesystem paths. Keep the domain boring and portable: every other module
//! depends on these types, and they depend on nothing but `serde`.

pub mod action_item;
pub mod decision;
pub mod meeting;
pub mod meeting_ir;
pub mod participant;
pub mod transcript;

pub use action_item::ActionItem;
pub use decision::Decision;
pub use meeting::Meeting;
pub use meeting_ir::MeetingIr;
pub use participant::Participant;
pub use transcript::{Transcript, TranscriptSegment};

/// A span of time within the meeting's source media, in seconds.
///
/// This is the unit of *evidence*: extracted facts point back to the transcript/audio
/// via an [`Evidence`] span so every claim in the MOM is traceable.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Evidence {
    pub start: f64,
    pub end: f64,
}
