//! Drives a meeting through every processing stage and emits granular progress events.
//!
//! The orchestrator owns the ORDER of operations and nothing else. It depends only on the
//! abstractions (`MediaProcessor`, `AsrProvider`, `AiAnalyzer`, `Store`) and the deterministic
//! `preprocess`/`renderer` helpers — never on FFmpeg command lines, ASR HTTP, or Ollama HTTP.
//!
//! ```text
//! Audio ─► media ─► ASR ─► Transcript ─► deterministic chunking ─► per-chunk extraction
//!        ─► synthesis ─► Meeting IR ─► validation ─► deterministic renderer ─► Markdown ─► storage
//! ```

use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::broadcast::Sender as BroadcastSender;

use crate::ai::{validation, AiAnalyzer, AiError, AnalysisContext, ChunkFindings};
use crate::asr::{AsrError, AsrProvider, AudioInput};
use crate::config::ChunkingConfig;
use crate::domain::{Meeting, MeetingId, MeetingIr, ProcessingStatus, Transcript};
use crate::ipc::events::Event;
use crate::media::{ExtractOptions, MediaError, MediaProcessor};
use crate::preprocess::{self, PreparedTranscript};
use crate::renderer::markdown;
use crate::storage::{StorageError, Store};

use super::jobs::{CancelFlag, JobId, JobRegistry, JobStage, JobStatus};

/// What to process into a meeting.
pub enum MeetingInput {
    /// Analyze an already-available transcript (skips media + ASR).
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

/// Sink for progress events. A broadcast channel so any number of connected IPC clients can observe
/// a job's progress. Sends are best-effort: `let _ = sink.send(..)` ignores "no subscribers".
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
    chunking: ChunkingConfig,
}

impl Orchestrator {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        media: Arc<dyn MediaProcessor>,
        asr: Arc<dyn AsrProvider>,
        ai: Arc<dyn AiAnalyzer>,
        store: Arc<dyn Store>,
        jobs: JobRegistry,
        data_dir: PathBuf,
        chunking: ChunkingConfig,
    ) -> Self {
        Self {
            media,
            asr,
            ai,
            store,
            jobs,
            data_dir,
            chunking,
        }
    }

    /// Run the full pipeline for a new meeting, updating the job registry and emitting events.
    pub async fn process(
        &self,
        job_id: &JobId,
        input: MeetingInput,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingId, PipelineError> {
        let result = self.run(job_id, input, events, cancel).await;
        self.finalize(job_id, result, events).await
    }

    /// Re-run AI enrichment for an already-captured meeting, from its stored transcript.
    ///
    /// This is the retry path for a deferred/failed capture: the source (transcript) is already
    /// safely persisted, so we never re-capture and never create a second meeting — the enrichment
    /// is simply recomputed and its artifacts upserted. Idempotent by construction.
    pub async fn reprocess(
        &self,
        job_id: &JobId,
        meeting_id: &MeetingId,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingId, PipelineError> {
        let result = self.rerun(job_id, meeting_id, events, cancel).await;
        self.finalize(job_id, result, events).await
    }

    /// Apply the terminal outcome: update the job, persist a durable [`ProcessingStatus`], and emit
    /// the terminal event. The source is already saved by this point, so a failure only defers/marks
    /// enrichment — it never risks the capture.
    async fn finalize(
        &self,
        job_id: &JobId,
        result: Result<MeetingId, PipelineError>,
        events: &EventSink,
    ) -> Result<MeetingId, PipelineError> {
        // `run`/`rerun` set the meeting id on the job early, so it's available even on failure.
        let meeting_id = self.jobs.get(job_id).and_then(|j| j.meeting_id);
        match &result {
            Ok(id) => {
                self.jobs.update(job_id, |j| {
                    j.status = JobStatus::Completed;
                    j.stage = JobStage::Done;
                    j.meeting_id = Some(id.clone());
                });
                self.persist_status(id, ProcessingStatus::ready()).await;
                let _ = events.send(Event::JobCompleted {
                    job_id: job_id.clone(),
                    meeting_id: id.clone(),
                });
            }
            Err(PipelineError::Cancelled) => {
                self.jobs
                    .update(job_id, |j| j.status = JobStatus::Cancelled);
                // Cancelled work is retryable — the source is intact.
                if let Some(id) = &meeting_id {
                    self.persist_status(id, ProcessingStatus::deferred("cancelled"))
                        .await;
                }
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
                if let Some(id) = &meeting_id {
                    // Storage failures need attention; runtime/model/network failures are retryable.
                    let status = match err {
                        PipelineError::Storage(_) => ProcessingStatus::failed(message.clone()),
                        _ => ProcessingStatus::deferred(message.clone()),
                    };
                    self.persist_status(id, status).await;
                }
                let _ = events.send(Event::JobFailed {
                    job_id: job_id.clone(),
                    message,
                });
            }
        }
        result
    }

    /// Persist a processing status best-effort: it's operational metadata, so a write failure here
    /// must never itself become a pipeline error (that would risk masking the real outcome).
    async fn persist_status(&self, id: &MeetingId, status: ProcessingStatus) {
        if let Err(e) = self.store.save_processing_status(id, &status).await {
            tracing::warn!("failed to persist processing status for {id}: {e}");
        }
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

        // 2. Obtain the raw transcript (either provided, or via media → ASR). Preserved as-is.
        // THIS is the source of truth: once it (and the meeting) are persisted below, the capture
        // is safe. Everything after is derived enrichment that can fail and be retried.
        let raw_transcript = match input {
            MeetingInput::Transcript { transcript, .. } => transcript,
            MeetingInput::Audio { path, .. } => {
                self.media_and_asr(job_id, &path, events, cancel).await?
            }
        };
        self.store
            .save_transcript(&meeting.id, &raw_transcript)
            .await?;
        // Source is now safe; mark enrichment in-flight so an interruption is recoverable.
        self.persist_status(&meeting.id, ProcessingStatus::processing())
            .await;
        check_cancel(cancel)?;

        // 3-6. Derived enrichment (chunk → AI → render → store). Shared with the retry path.
        self.enrich(
            job_id,
            &mut meeting,
            &raw_transcript,
            &context,
            events,
            cancel,
        )
        .await?;
        Ok(meeting.id)
    }

    /// Re-run enrichment for an existing meeting from its stored transcript (the retry path).
    async fn rerun(
        &self,
        job_id: &JobId,
        meeting_id: &MeetingId,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingId, PipelineError> {
        self.jobs.update(job_id, |j| {
            j.status = JobStatus::Running;
            j.meeting_id = Some(meeting_id.clone());
        });

        let mut meeting = self.store.get_meeting(meeting_id).await?.ok_or_else(|| {
            PipelineError::Storage(StorageError::Backend(format!(
                "cannot reprocess unknown meeting: {meeting_id}"
            )))
        })?;
        let transcript = self
            .store
            .get_transcript(meeting_id)
            .await?
            .ok_or_else(|| {
                PipelineError::Storage(StorageError::Backend(format!(
                    "cannot reprocess meeting without a stored transcript: {meeting_id}"
                )))
            })?;

        self.persist_status(meeting_id, ProcessingStatus::processing())
            .await;
        let _ = events.send(Event::ProcessingStarted {
            job_id: job_id.clone(),
            meeting_id: meeting_id.clone(),
        });
        check_cancel(cancel)?;

        let context = AnalysisContext {
            title: Some(meeting.title.clone()),
        };
        self.enrich(job_id, &mut meeting, &transcript, &context, events, cancel)
            .await?;
        Ok(meeting.id)
    }

    /// Derived enrichment from a persisted transcript: chunk → two-pass AI → render → store.
    /// Shared by first-time processing and retry; all writes upsert, so it is safe to re-run.
    async fn enrich(
        &self,
        job_id: &JobId,
        meeting: &mut Meeting,
        transcript: &Transcript,
        context: &AnalysisContext,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<(), PipelineError> {
        // Deterministic Rust: normalize + chunk (no LLM).
        self.stage(job_id, JobStage::Chunking);
        let _ = events.send(Event::ChunkingStarted {
            job_id: job_id.clone(),
        });
        let prepared = preprocess::prepare(transcript, &self.chunking);
        let _ = events.send(Event::ChunkingCompleted {
            job_id: job_id.clone(),
            chunk_count: prepared.chunks.len(),
        });
        check_cancel(cancel)?;

        // AI: per-chunk extraction → synthesis → validation.
        let ir = self
            .analyze(job_id, &prepared, context, events, cancel)
            .await?;
        self.store.save_meeting_ir(&meeting.id, &ir).await?;

        // Deterministic rendering → Markdown MOM (no LLM here).
        self.stage(job_id, JobStage::Rendering);
        let _ = events.send(Event::RenderingStarted {
            job_id: job_id.clone(),
        });
        let mom = markdown::render_with_title(&ir, &meeting.title);
        let _ = events.send(Event::RenderingCompleted {
            job_id: job_id.clone(),
        });

        // Persist artifacts + meeting metadata (participants learned during analysis).
        self.stage(job_id, JobStage::Storing);
        self.store.save_mom(&meeting.id, &mom).await?;
        meeting.participants = ir.participants.clone();
        self.store.save_meeting(meeting).await?;
        Ok(())
    }

    /// Media normalization + ASR for the audio input path.
    async fn media_and_asr(
        &self,
        job_id: &JobId,
        path: &std::path::Path,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<Transcript, PipelineError> {
        self.stage(job_id, JobStage::MediaProcessing);
        let _ = events.send(Event::MediaProcessingStarted {
            job_id: job_id.clone(),
        });
        let out_dir = self.data_dir.join("work").join(&job_id.0);
        let prepared_audio = self
            .media
            .extract_audio(path, &out_dir, &ExtractOptions::default())
            .await?;
        let _ = events.send(Event::MediaProcessingCompleted {
            job_id: job_id.clone(),
        });
        check_cancel(cancel)?;

        self.stage(job_id, JobStage::Transcription);
        let _ = events.send(Event::TranscriptionStarted {
            job_id: job_id.clone(),
        });
        // Our ASR providers return the full transcript at once (no sub-progress), so we emit
        // stage-level start/complete rather than faking granular TranscriptionProgress.
        let transcript = self
            .asr
            .transcribe(&AudioInput::new(prepared_audio.path))
            .await?;
        let _ = events.send(Event::TranscriptionCompleted {
            job_id: job_id.clone(),
        });
        Ok(transcript)
    }

    /// Transcribe a single audio file synchronously: media normalize (FFmpeg → 16 kHz mono) → ASR →
    /// [Transcript]. No job, no events, no storage — this backs the live per-segment `TranscribeChunk`
    /// request. The normalized WAV is written under `data_dir/tmp/<nanos>` and cleaned up after ASR
    /// reads it. Errors degrade honestly (Media/Asr → `PipelineError`).
    pub async fn transcribe_one(
        &self,
        path: &std::path::Path,
    ) -> Result<Transcript, PipelineError> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let out_dir = self.data_dir.join("tmp").join(format!("chunk-{nanos}"));
        let prepared = self
            .media
            .extract_audio(path, &out_dir, &ExtractOptions::default())
            .await?;
        let transcript = self.asr.transcribe(&AudioInput::new(prepared.path)).await?;
        let _ = tokio::fs::remove_dir_all(&out_dir).await; // best-effort cleanup
        Ok(transcript)
    }

    /// The two-pass AI analysis with per-chunk extraction progress and validation events.
    async fn analyze(
        &self,
        job_id: &JobId,
        prepared: &PreparedTranscript,
        context: &AnalysisContext,
        events: &EventSink,
        cancel: &CancelFlag,
    ) -> Result<MeetingIr, PipelineError> {
        let total = prepared.chunks.len();

        // Empty transcript → deterministic IR, no LLM call, no invention.
        if total == 0 {
            let ir = MeetingIr {
                summary: "No transcript content was available to analyze.".to_string(),
                ..Default::default()
            };
            self.validate_stage(job_id, &ir, events)?;
            return Ok(ir);
        }

        // Extraction pass (per chunk).
        self.stage(job_id, JobStage::Extraction);
        let _ = events.send(Event::ExtractionStarted {
            job_id: job_id.clone(),
            chunk_count: total,
        });
        let mut findings: Vec<ChunkFindings> = Vec::with_capacity(total);
        for (i, chunk) in prepared.chunks.iter().enumerate() {
            check_cancel(cancel)?;
            findings.push(self.ai.extract_chunk(chunk, context).await?);
            let _ = events.send(Event::ExtractionProgress {
                job_id: job_id.clone(),
                completed: i + 1,
                total,
            });
        }
        let _ = events.send(Event::ExtractionCompleted {
            job_id: job_id.clone(),
        });
        check_cancel(cancel)?;

        // Synthesis pass (consolidate → Meeting IR).
        self.stage(job_id, JobStage::Synthesis);
        let _ = events.send(Event::SynthesisStarted {
            job_id: job_id.clone(),
        });
        let ir = self
            .ai
            .synthesize(&findings, &prepared.normalized, context)
            .await?;
        let _ = events.send(Event::SynthesisCompleted {
            job_id: job_id.clone(),
        });
        check_cancel(cancel)?;

        // Validation.
        self.validate_stage(job_id, &ir, events)?;
        Ok(ir)
    }

    fn validate_stage(
        &self,
        job_id: &JobId,
        ir: &MeetingIr,
        events: &EventSink,
    ) -> Result<(), PipelineError> {
        self.stage(job_id, JobStage::Validation);
        let _ = events.send(Event::ValidationStarted {
            job_id: job_id.clone(),
        });
        validation::validate(ir)
            .map_err(|errs| PipelineError::Ai(AiError::Validation(errs.join("; "))))?;
        let _ = events.send(Event::ValidationCompleted {
            job_id: job_id.clone(),
        });
        Ok(())
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
