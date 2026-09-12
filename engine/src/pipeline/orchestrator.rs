//! Drives a meeting through every processing stage and emits progress events.
//!
//! The orchestrator owns the ORDER of operations and nothing else: it depends only on the
//! abstractions (`MediaProcessor`, `AsrProvider`, `AiAnalyzer`, `Store`) — never on FFmpeg command
//! lines or Ollama HTTP. Each module performs its own responsibility.
//!
//! ```text
//! input → [media → ASR] → transcript → AI analyze → Meeting IR → validate → render → store
//! ```

use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::broadcast::Sender as BroadcastSender;

use crate::ai::{AiAnalyzer, AiError, AnalysisContext};
use crate::asr::{AsrError, AsrProvider, AudioInput};
use crate::domain::{Meeting, MeetingId, Transcript};
use crate::ipc::events::Event;
use crate::media::{ExtractOptions, MediaError, MediaProcessor};
use crate::renderer::markdown;
use crate::storage::{StorageError, Store};

use super::jobs::{CancelFlag, JobId, JobRegistry, JobStage, JobStatus};

/// What to process into a meeting.
pub enum MeetingInput {
    /// Analyze an already-available transcript (the supported v0 path).
    Transcript {
        title: Option<String>,
        transcript: Transcript,
    },
    /// Process audio (requires media + ASR).
    Audio {
        title: Option<String>,
        path: PathBuf,
    },
}

impl MeetingInput {
    fn title(&self) -> String {
        let t = match self {
            MeetingInput::Transcript { title, .. } => title,
            MeetingInput::Audio { title, .. } => title,
        };
        t.clone().unwrap_or_else(|| "Untitled meeting".to_string())
    }
}

/// Sink for progress events. A broadcast channel so any number of connected IPC clients can
/// observe a job's progress. Sends are best-effort: `let _ = sink.send(..)` ignores "no
/// subscribers".
pub type EventSink = BroadcastSender<Event>;

#[derive(Debug, thiserror::Error)]
pub enum PipelineError {
    #[error("job was cancelled")]
    Cancelled,
    #[error(transparent)]
    Media(#[from] MediaError),
    #[error(transparent)]
    Asr(#[from] AsrError),
    #[error(transparent)]
    Ai(#[from] AiError),
    #[error(transparent)]
    Storage(#[from] StorageError),
}

/// Coordinates the stages for a single meeting.
#[derive(Clone)]
pub struct Orchestrator {
    media: Arc<dyn MediaProcessor>,
    asr: Arc<dyn AsrProvider>,
    ai: Arc<dyn AiAnalyzer>,
    store: Arc<dyn Store>,
    jobs: JobRegistry,
    data_dir: PathBuf,
}

impl Orchestrator {
    pub fn new(
        media: Arc<dyn MediaProcessor>,
        asr: Arc<dyn AsrProvider>,
        ai: Arc<dyn AiAnalyzer>,
        store: Arc<dyn Store>,
        jobs: JobRegistry,
        data_dir: PathBuf,
    ) -> Self {
        Self {
            media,
            asr,
            ai,
            store,
            jobs,
            data_dir,
        }
    }

    /// Run the full pipeline for one meeting, updating the job registry and emitting events.
    pub async fn process(
        &self,
        job_id: &JobId,
        input: MeetingInput,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingId, PipelineError> {
        let result = self.run(job_id, input, events, cancel).await;
        match &result {
            Ok(meeting_id) => {
                self.jobs.update(job_id, |j| {
                    j.status = JobStatus::Completed;
                    j.stage = JobStage::Done;
                    j.meeting_id = Some(meeting_id.clone());
                });
                let _ = events.send(Event::JobCompleted {
                    job_id: job_id.clone(),
                    meeting_id: meeting_id.clone(),
                });
            }
            Err(PipelineError::Cancelled) => {
                self.jobs
                    .update(job_id, |j| j.status = JobStatus::Cancelled);
                let _ = events.send(Event::JobFailed {
                    job_id: job_id.clone(),
                    message: "cancelled".to_string(),
                });
            }
            Err(err) => {
                let message = err.to_string();
                self.jobs.update(job_id, |j| {
                    j.status = JobStatus::Failed;
                    j.error = Some(message.clone());
                });
                let _ = events.send(Event::JobFailed {
                    job_id: job_id.clone(),
                    message,
                });
            }
        }
        result
    }

    async fn run(
        &self,
        job_id: &JobId,
        input: MeetingInput,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingId, PipelineError> {
        self.jobs.update(job_id, |j| j.status = JobStatus::Running);

        // 1. Create + persist the meeting record.
        let mut meeting = Meeting::new(input.title());
        let context = AnalysisContext {
            title: Some(meeting.title.clone()),
        };
        self.store.save_meeting(&meeting).await?;
        self.jobs
            .update(job_id, |j| j.meeting_id = Some(meeting.id.clone()));
        let _ = events.send(Event::ProcessingStarted {
            job_id: job_id.clone(),
            meeting_id: meeting.id.clone(),
        });
        check_cancel(cancel)?;

        // 2. Obtain a transcript (either provided, or via media → ASR).
        let transcript = match input {
            MeetingInput::Transcript { transcript, .. } => transcript,
            MeetingInput::Audio { path, .. } => {
                self.stage(job_id, JobStage::MediaProcessing);
                let out_dir = self.data_dir.join("work").join(&job_id.0);
                let prepared = self
                    .media
                    .extract_audio(&path, &out_dir, &ExtractOptions::default())
                    .await?;
                check_cancel(cancel)?;

                self.stage(job_id, JobStage::Transcription);
                let _ = events.send(Event::TranscriptionStarted {
                    job_id: job_id.clone(),
                });
                self.asr.transcribe(&AudioInput::new(prepared.path)).await?
            }
        };
        self.store.save_transcript(&meeting.id, &transcript).await?;
        check_cancel(cancel)?;

        // 3. AI analysis → Meeting IR (extraction + synthesis + validation happen inside).
        self.stage(job_id, JobStage::Analysis);
        let _ = events.send(Event::AnalysisStarted {
            job_id: job_id.clone(),
        });
        let ir = self.ai.analyze(&transcript, &context).await?;
        self.store.save_meeting_ir(&meeting.id, &ir).await?;
        check_cancel(cancel)?;

        // 4. Deterministic rendering → Markdown MOM (no LLM here).
        self.stage(job_id, JobStage::Rendering);
        let _ = events.send(Event::RenderingStarted {
            job_id: job_id.clone(),
        });
        let mom = markdown::render_with_title(&ir, &meeting.title);

        // 5. Persist artifacts + meeting metadata (participants learned during analysis).
        self.stage(job_id, JobStage::Storing);
        self.store.save_mom(&meeting.id, &mom).await?;
        meeting.participants = ir.participants.clone();
        self.store.save_meeting(&meeting).await?;

        Ok(meeting.id)
    }

    fn stage(&self, job_id: &JobId, stage: JobStage) {
        self.jobs.update(job_id, |j| j.stage = stage);
    }
}

fn check_cancel(cancel: &CancelFlag) -> Result<(), PipelineError> {
    if cancel.is_cancelled() {
        Err(PipelineError::Cancelled)
    } else {
        Ok(())
    }
}
