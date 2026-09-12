//! Orchestration layer.
//!
//! The pipeline coordinates the other components in order but contains NO provider-specific
//! implementations. It knows the *stages*, not how any stage is implemented:
//!
//! ```text
//! input meeting → media → ASR → transcript processing → AI extraction
//!   → AI synthesis → MeetingIR validation → rendering → storage
//! ```
//!
//! See `docs/pipeline.md`.

pub mod jobs;
pub mod orchestrator;

pub use jobs::{Job, JobStatus};
pub use orchestrator::Orchestrator;
