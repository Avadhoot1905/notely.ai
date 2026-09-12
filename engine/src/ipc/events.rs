//! Asynchronous events streamed Engine → Flutter while a job runs.
//!
//! Requests return quickly (usually with a [`JobId`]); real pipeline progress is reported here so
//! the UI can show live status without blocking. Every event carries the `job_id` it belongs to.
//! The set mirrors the pipeline stages in `docs/pipeline.md`. Granular progress is emitted where a
//! stage can measure it (transcription, extraction); otherwise stage-level start/complete events
//! are used. No fake progress is ever emitted.

use serde::{Deserialize, Serialize};

use crate::domain::MeetingId;
use crate::pipeline::jobs::JobId;

/// Lifecycle + progress events for a job.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Event {
    JobCreated {
        job_id: JobId,
    },
    /// The meeting record exists; carries its id so the UI can navigate early.
    ProcessingStarted {
        job_id: JobId,
        meeting_id: MeetingId,
    },

    MediaProcessingStarted {
        job_id: JobId,
    },
    MediaProcessingCompleted {
        job_id: JobId,
    },

    TranscriptionStarted {
        job_id: JobId,
    },
    /// `progress` in 0.0..=1.0 when the ASR provider reports it.
    TranscriptionProgress {
        job_id: JobId,
        progress: f32,
    },
    TranscriptionCompleted {
        job_id: JobId,
    },

    ChunkingStarted {
        job_id: JobId,
    },
    ChunkingCompleted {
        job_id: JobId,
        chunk_count: usize,
    },

    ExtractionStarted {
        job_id: JobId,
        chunk_count: usize,
    },
    /// `completed` of `total` chunks extracted.
    ExtractionProgress {
        job_id: JobId,
        completed: usize,
        total: usize,
    },
    ExtractionCompleted {
        job_id: JobId,
    },

    SynthesisStarted {
        job_id: JobId,
    },
    SynthesisCompleted {
        job_id: JobId,
    },

    ValidationStarted {
        job_id: JobId,
    },
    ValidationCompleted {
        job_id: JobId,
    },

    RenderingStarted {
        job_id: JobId,
    },
    RenderingCompleted {
        job_id: JobId,
    },

    JobCompleted {
        job_id: JobId,
        meeting_id: MeetingId,
    },
    JobFailed {
        job_id: JobId,
        message: String,
    },
}

/// Outgoing event wrapper on the wire, so clients can distinguish events from responses
/// (responses carry a `request_id`; events carry an `event`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub protocol_version: u32,
    pub event: Event,
}

impl Event {
    /// The job this event belongs to.
    pub fn job_id(&self) -> &JobId {
        match self {
            Event::JobCreated { job_id }
            | Event::ProcessingStarted { job_id, .. }
            | Event::MediaProcessingStarted { job_id }
            | Event::MediaProcessingCompleted { job_id }
            | Event::TranscriptionStarted { job_id }
            | Event::TranscriptionProgress { job_id, .. }
            | Event::TranscriptionCompleted { job_id }
            | Event::ChunkingStarted { job_id }
            | Event::ChunkingCompleted { job_id, .. }
            | Event::ExtractionStarted { job_id, .. }
            | Event::ExtractionProgress { job_id, .. }
            | Event::ExtractionCompleted { job_id }
            | Event::SynthesisStarted { job_id }
            | Event::SynthesisCompleted { job_id }
            | Event::ValidationStarted { job_id }
            | Event::ValidationCompleted { job_id }
            | Event::RenderingStarted { job_id }
            | Event::RenderingCompleted { job_id }
            | Event::JobCompleted { job_id, .. }
            | Event::JobFailed { job_id, .. } => job_id,
        }
    }
}
