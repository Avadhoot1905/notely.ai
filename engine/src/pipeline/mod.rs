//! Orchestration layer.
//!
//! The pipeline coordinates the other components in order but contains NO provider-specific
//! implementations. It knows the *stages*, not how any stage is implemented:
//!
//! ```text
//! input meeting → [media → ASR] → transcript → AI analyze → Meeting IR → render → store
//! ```
//!
//! See `docs/pipeline.md`.

pub mod job_store;
pub mod jobs;
pub mod orchestrator;

pub use job_store::{JobStore, JobStoreError};
pub use jobs::{CancelFlag, Job, JobId, JobKind, JobRegistry, JobStage, JobStatus};
pub use orchestrator::{EventSink, MeetingInput, Orchestrator, PipelineError};
