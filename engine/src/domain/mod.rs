//! Application concepts only — the portable core of Notely.
//!
//! Types here describe *what a meeting is*, not how it is captured, processed, stored, or
//! displayed. They MUST NOT depend on Ollama, Qwen, FFmpeg, IPC, the database, or Flutter.
//! Every other module depends on these types; they depend on nothing but `serde` (+ `chrono`
//! for timestamps). Keep the domain boring and portable.

pub mod action_item;
pub mod decision;
pub mod knowledge;
pub mod meeting;
pub mod meeting_ir;
pub mod participant;
pub mod processing;
pub mod transcript;

pub use action_item::{ActionItem, ActionStatus};
pub use decision::Decision;
pub use knowledge::{AskAnswer, Citation, SearchHit};
pub use meeting::{Meeting, MeetingId};
pub use meeting_ir::{Evidence, MeetingIr, OpenQuestion, Risk, Topic};
pub use participant::Participant;
pub use processing::{FailureKind, MeetingSummary, ProcessingState, ProcessingStatus};
pub use transcript::{Transcript, TranscriptSegment};
