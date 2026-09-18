//! Notely engine — the single local backend for the Notely desktop app.
//!
//! The engine is the ONE Rust package in this repository. It is internally modular (the modules
//! below) but is intentionally not split into multiple crates. Flutter talks to it exclusively
//! over the IPC boundary in [`ipc`].
//!
//! This crate is both a library (so its modules are unit/integration testable — see
//! `engine/tests`) and a thin binary (`src/main.rs`), which just calls [`run`].

// A few stage backends (Whisper ASR, HTML renderer) are defined boundaries without an
// implementation yet; their honest "not implemented" paths mean some variants are constructed
// only in tests. Keep the surface tidy rather than sprinkling per-item allows.
#![allow(dead_code)]

pub mod ai;
pub mod asr;
pub mod config;
pub mod domain;
pub mod ipc;
pub mod llm;
pub mod media;
pub mod pipeline;
pub mod preprocess;
pub mod renderer;
pub mod search;
pub mod storage;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tokio::sync::broadcast;

use std::collections::HashMap;

use crate::ai::{AiAnalyzer, AnalysisContext, LlmAiEngine};
use crate::config::{Config, LlmProviderKind};
use crate::domain::{
    Meeting, MeetingId, MeetingIr, MeetingSummary, ProcessingState, ProcessingStatus, Transcript,
};
use crate::ipc::events::Event;
use crate::ipc::protocol::{HealthInfo, ProcessInput, Request, Response, PROTOCOL_VERSION};
use crate::llm::{
    CachingLlmProvider, EmbedRequest, LlmCache, LlmProvider, MlxProvider, OllamaProvider,
};
use crate::media::FfmpegMediaProcessor;
use crate::pipeline::jobs::JobId;
use crate::pipeline::{
    JobKind, JobRegistry, JobStage, JobStatus, JobStore, MeetingInput, Orchestrator,
};
use crate::renderer::markdown;
use crate::search::{qa, Passage, SearchIndex};
use crate::storage::{SqliteStore, Store};

/// Capacity of the per-engine event broadcast buffer.
const EVENT_CHANNEL_CAPACITY: usize = 256;

/// The assembled engine: configuration + providers + storage + pipeline, ready to serve IPC.
///
/// Construct with [`Engine::new`], dispatch [`Request`]s with [`Engine::dispatch`], and observe
/// job progress with [`Engine::subscribe`].
pub struct Engine {
    config: Config,
    store: Arc<dyn Store>,
    llm: Arc<dyn LlmProvider>,
    ai: Arc<dyn AiAnalyzer>,
    search: SearchIndex,
    jobs: JobRegistry,
    orchestrator: Orchestrator,
    events: broadcast::Sender<Event>,
    /// Guards against overlapping background embedding passes (coalesces concurrent triggers).
    embedding_in_progress: Arc<AtomicBool>,
}

impl Engine {
    /// Initialize storage and providers from configuration and wire up the pipeline.
    ///
    /// Two independent runtimes are wired here: the LLM (Ollama) and ASR (a separate runtime; the
    /// default Qwen3-ASR provider is HTTP-based — see `engine/src/asr`).
    pub fn new(config: Config) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&config.data_dir)?;
        let store: Arc<dyn Store> = Arc::new(SqliteStore::open(config.database_path())?);
        let search = SearchIndex::open(config.search_index_path())?;

        // Select the LLM runtime (all behind the same provider boundary). Ollama is the default and
        // remains the CUDA/NVIDIA and cross-platform path; MLX is an opt-in Apple-Silicon sibling.
        let base_llm: Arc<dyn LlmProvider> = match config.llm_provider {
            LlmProviderKind::Ollama => Arc::new(OllamaProvider::new(&config.ollama)?),
            LlmProviderKind::Mlx => Arc::new(MlxProvider::new(&config.mlx)?),
        };
        // Wrap the runtime in a transparent result cache. Best-effort: if the cache file can't be
        // opened we simply run without it (current behavior), never failing startup.
        let active_model = config.active_model().to_string();
        let llm: Arc<dyn LlmProvider> = match LlmCache::open(config.llm_cache_path()) {
            Ok(cache) => Arc::new(CachingLlmProvider::new(base_llm, cache, active_model)),
            Err(e) => {
                tracing::warn!("LLM result cache unavailable ({e}); continuing without it");
                base_llm
            }
        };

        let media = Arc::new(FfmpegMediaProcessor::new());
        let asr = asr::from_config(&config.asr)?; // Qwen3-ASR by default (separate runtime).
        let ai: Arc<dyn AiAnalyzer> = Arc::new(LlmAiEngine::new(llm.clone()).with_models(
            config.models.extraction.clone(),
            config.models.synthesis.clone(),
        ));
        // Persist the job queue so background work survives a restart. Best-effort: degrade to an
        // in-memory registry if the store can't be opened.
        let jobs = match JobStore::open(config.jobs_path()) {
            Ok(store) => JobRegistry::with_store(store),
            Err(e) => {
                tracing::warn!(
                    "job store unavailable ({e}); jobs will not persist across restarts"
                );
                JobRegistry::new()
            }
        };
        let (events, _rx) = broadcast::channel(EVENT_CHANNEL_CAPACITY);

        let orchestrator = Orchestrator::new(
            media,
            asr,
            ai.clone(),
            store.clone(),
            jobs.clone(),
            config.data_dir.clone(),
            config.chunking.clone(),
        );

        Ok(Self {
            config,
            store,
            llm,
            ai,
            search,
            jobs,
            orchestrator,
            events,
            embedding_in_progress: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Subscribe to the job event stream.
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    /// Handle a single request. Long-running work is spawned and reported via events.
    pub async fn dispatch(&self, request: Request) -> Response {
        match request {
            Request::Health => Response::Health(self.health().await),
            Request::ProcessMeeting { input } => self.start_processing(input),
            Request::GetJob { job_id } => match self.jobs.get(&job_id) {
                Some(job) => Response::Job(job),
                None => Response::Error {
                    message: format!("unknown job: {job_id}"),
                },
            },
            Request::CancelJob { job_id } => {
                if self.jobs.request_cancel(&job_id) {
                    match self.jobs.get(&job_id) {
                        Some(job) => Response::Job(job),
                        None => Response::Error {
                            message: format!("unknown job: {job_id}"),
                        },
                    }
                } else {
                    Response::Error {
                        message: format!("unknown job: {job_id}"),
                    }
                }
            }
            Request::GetMeeting { meeting_id } => self.get_meeting(&meeting_id).await,
            Request::GetTranscript { meeting_id } => self.get_transcript(&meeting_id).await,
            Request::GetMom { meeting_id } => self.get_mom(&meeting_id).await,
            Request::Search {
                query,
                vault_path,
                limit,
            } => self.search_vault(&query, &vault_path, limit).await,
            Request::Ask {
                question,
                vault_path,
            } => self.ask_vault(&question, &vault_path).await,
            Request::ListMeetings => self.list_meetings().await,
            Request::ReprocessMeeting { meeting_id } => self.start_reprocessing(meeting_id),
        }
    }

    async fn health(&self) -> HealthInfo {
        let llm_ok = self.llm.health().await.is_ok();
        HealthInfo {
            protocol_version: PROTOCOL_VERSION,
            engine_ok: true,
            llm_ok,
            model: self.config.active_model().to_string(),
            asr_provider: format!("{:?}", self.config.asr.provider).to_lowercase(),
        }
    }

    /// Create a job and spawn the pipeline; return the job id immediately.
    fn start_processing(&self, input: ProcessInput) -> Response {
        let (job_id, cancel) = self.jobs.create(JobKind::Process);
        let _ = self.events.send(Event::JobCreated {
            job_id: job_id.clone(),
        });

        let meeting_input = match input {
            ProcessInput::Transcript { title, transcript } => {
                MeetingInput::Transcript { title, transcript }
            }
            ProcessInput::Audio { title, path } => MeetingInput::Audio {
                title,
                path: path.into(),
            },
        };

        let orchestrator = self.orchestrator.clone();
        let events = self.events.clone();
        let job = job_id.clone();
        tokio::spawn(async move {
            let _ = orchestrator
                .process(&job, meeting_input, &events, &cancel)
                .await;
        });

        Response::JobAccepted { job_id }
    }

    /// Retry AI enrichment for an existing meeting; return the job id immediately. The source
    /// transcript is already persisted, so this never re-captures and never creates a new meeting.
    fn start_reprocessing(&self, meeting_id: MeetingId) -> Response {
        let (job_id, cancel) = self.jobs.create(JobKind::Reprocess);
        let _ = self.events.send(Event::JobCreated {
            job_id: job_id.clone(),
        });

        let orchestrator = self.orchestrator.clone();
        let events = self.events.clone();
        let job = job_id.clone();
        tokio::spawn(async move {
            let _ = orchestrator
                .reprocess(&job, &meeting_id, &events, &cancel)
                .await;
        });

        Response::JobAccepted { job_id }
    }

    /// List captured meetings with their processing status (newest first). Meetings with no stored
    /// status predate the reliability layer and are treated as already enriched by the UI.
    async fn list_meetings(&self) -> Response {
        let meetings = match self.store.list_meetings().await {
            Ok(m) => m,
            Err(e) => {
                return Response::Error {
                    message: e.to_string(),
                }
            }
        };
        let statuses: HashMap<String, ProcessingStatus> = self
            .store
            .list_processing_statuses()
            .await
            .unwrap_or_default()
            .into_iter()
            .map(|(id, s)| (id.0, s))
            .collect();
        let summaries = meetings
            .into_iter()
            .map(|m| {
                let status = statuses.get(&m.id.0).cloned();
                MeetingSummary { meeting: m, status }
            })
            .collect();
        Response::MeetingList(summaries)
    }

    /// Startup recovery: any capture left in `Processing` (interrupted by a crash/exit) is marked
    /// `Deferred` so it surfaces as retryable rather than appearing stuck or lost. Idempotent — it
    /// only touches `Processing` rows and never creates or duplicates a capture. Returns the count.
    pub async fn recover_interrupted(&self) -> usize {
        let statuses = match self.store.list_processing_statuses().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("recovery: could not list processing statuses: {e}");
                return 0;
            }
        };
        let mut recovered = 0;
        for (id, status) in statuses {
            if status.state == ProcessingState::Processing {
                let deferred = ProcessingStatus::deferred("processing was interrupted; will retry");
                if self
                    .store
                    .save_processing_status(&id, &deferred)
                    .await
                    .is_ok()
                {
                    recovered += 1;
                }
            }
        }
        if recovered > 0 {
            tracing::info!("recovery: {recovered} interrupted capture(s) marked deferred");
        }
        recovered
    }

    /// Startup recovery for the persistent job queue: requeue anything that was `Queued`/`Running`
    /// when the process died. Resumption uses the idempotent reprocess path (the source transcript
    /// is already safe), so it never re-captures or duplicates a meeting. Retries are bounded
    /// (`MAX_JOB_ATTEMPTS`) and a job with no resumable transcript is closed as failed rather than
    /// looping. Embedding jobs are table-driven (self-heal on the next search) and just closed here.
    /// Returns how many jobs were requeued.
    pub async fn recover_jobs(&self) -> usize {
        const MAX_JOB_ATTEMPTS: u32 = 3;
        let Some(store) = self.jobs.store() else {
            return 0;
        };
        let unfinished = match store.list_unfinished() {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("job recovery: could not list unfinished jobs: {e}");
                return 0;
            }
        };
        let mut requeued = 0;
        for job in unfinished {
            match job.kind {
                JobKind::Embedding => {
                    // Pending embeddings are derived from the index, so they re-run on the next
                    // search; just close the stale row.
                    let mut done = job.clone();
                    done.status = JobStatus::Failed;
                    done.error = Some("interrupted; will re-embed on next search".to_string());
                    let _ = store.upsert(&done);
                }
                JobKind::Process | JobKind::Reprocess => {
                    let resumable = match &job.meeting_id {
                        Some(id) => self.store.get_transcript(id).await.ok().flatten().is_some(),
                        None => false,
                    };
                    if job.attempts >= MAX_JOB_ATTEMPTS || !resumable {
                        let mut failed = job.clone();
                        failed.status = JobStatus::Failed;
                        failed.error = Some(if resumable {
                            "exceeded retry budget".to_string()
                        } else {
                            "cannot resume: no stored transcript".to_string()
                        });
                        let _ = store.upsert(&failed);
                        continue;
                    }
                    let meeting_id = job.meeting_id.clone().expect("resumable implies a meeting");
                    // Re-register (bumping attempts) and resume via the idempotent reprocess path.
                    let mut resumed = job.clone();
                    resumed.attempts += 1;
                    resumed.status = JobStatus::Queued;
                    resumed.kind = JobKind::Reprocess;
                    let cancel = self.jobs.reinsert(resumed);
                    let orchestrator = self.orchestrator.clone();
                    let events = self.events.clone();
                    let jid = job.id.clone();
                    tokio::spawn(async move {
                        let _ = orchestrator
                            .reprocess(&jid, &meeting_id, &events, &cancel)
                            .await;
                    });
                    requeued += 1;
                }
            }
        }
        if requeued > 0 {
            tracing::info!("recovery: requeued {requeued} interrupted job(s)");
        }
        requeued
    }

    async fn get_meeting(&self, id: &MeetingId) -> Response {
        match self.store.get_meeting(id).await {
            Ok(Some(m)) => Response::Meeting(m),
            Ok(None) => Response::Error {
                message: format!("unknown meeting: {id}"),
            },
            Err(e) => Response::Error {
                message: e.to_string(),
            },
        }
    }

    async fn get_transcript(&self, id: &MeetingId) -> Response {
        match self.store.get_transcript(id).await {
            Ok(Some(t)) => Response::Transcript(t),
            Ok(None) => Response::Error {
                message: format!("no transcript for meeting: {id}"),
            },
            Err(e) => Response::Error {
                message: e.to_string(),
            },
        }
    }

    async fn get_mom(&self, id: &MeetingId) -> Response {
        match self.store.get_mom(id).await {
            Ok(Some(markdown)) => Response::Mom { markdown },
            Ok(None) => Response::Error {
                message: format!("no MOM for meeting: {id}"),
            },
            Err(e) => Response::Error {
                message: e.to_string(),
            },
        }
    }

    /// Keep the index fresh, then search the vault (hybrid FTS5 + vector when embeddings are on). A
    /// stale-sync failure is non-fatal: we still search whatever is already indexed.
    async fn search_vault(&self, query: &str, vault_path: &str, limit: Option<usize>) -> Response {
        if let Err(e) = self.search.sync_vault(vault_path.into()).await {
            tracing::warn!("vault sync failed before search: {e}");
        }
        self.maybe_spawn_embedding();
        let query_vector = self.embed_query(query).await;
        match self
            .search
            .retrieve_hybrid(query, limit.unwrap_or(20), query_vector)
            .await
        {
            Ok(passages) => Response::SearchResults(passages.iter().map(Passage::to_hit).collect()),
            Err(e) => Response::Error {
                message: e.to_string(),
            },
        }
    }

    /// Answer a question grounded in the vault. Never hard-fails: retrieval falls back to an empty
    /// set and [`qa::answer`] itself degrades to a source list if the LLM is unavailable, so Ask
    /// always returns something useful (see the "AI failure ≠ data loss" reliability rule).
    async fn ask_vault(&self, question: &str, vault_path: &str) -> Response {
        if let Err(e) = self.search.sync_vault(vault_path.into()).await {
            tracing::warn!("vault sync failed before ask: {e}");
        }
        self.maybe_spawn_embedding();
        let query_vector = self.embed_query(question).await;
        let passages = self
            .search
            .retrieve_hybrid(question, qa::DEFAULT_TOP_K, query_vector)
            .await
            .unwrap_or_default();
        let answer = qa::answer(
            question,
            &passages,
            self.llm.as_ref(),
            self.config.models.qa.as_deref(),
        )
        .await;
        Response::Answer(answer)
    }

    /// Embed a query for the vector side of hybrid search. Returns `None` — degrading to FTS5-only —
    /// when embeddings are off (no embedding model configured) or the embedder is unavailable.
    async fn embed_query(&self, query: &str) -> Option<Vec<f32>> {
        let model = self.config.models.embedding.as_deref()?;
        match self
            .llm
            .embed(EmbedRequest::new(
                Some(model.to_string()),
                vec![query.to_string()],
            ))
            .await
        {
            Ok(mut r) if !r.vectors.is_empty() => Some(r.vectors.remove(0)),
            Ok(_) => None,
            Err(e) => {
                tracing::warn!("query embedding failed; using FTS5 only: {e}");
                None
            }
        }
    }

    /// Kick a background embedding pass if embeddings are enabled and there is pending work. Runs as
    /// a tracked, persisted [`JobKind::Embedding`] job so it survives observation; coalesced by an
    /// atomic flag so overlapping searches don't launch duplicate passes. Non-blocking: note saving
    /// and search results never wait on embedding.
    fn maybe_spawn_embedding(&self) {
        let Some(model) = self.config.models.embedding.clone() else {
            return; // embeddings opt-in; off by default
        };
        if self.embedding_in_progress.swap(true, Ordering::SeqCst) {
            return; // a pass is already running
        }
        let search = self.search.clone();
        let llm = self.llm.clone();
        let jobs = self.jobs.clone();
        let flag = self.embedding_in_progress.clone();
        tokio::spawn(async move {
            let pending = search.pending_embedding_count().await.unwrap_or(0);
            if pending == 0 {
                flag.store(false, Ordering::SeqCst);
                return;
            }
            let (job_id, _cancel) = jobs.create(JobKind::Embedding);
            jobs.update(&job_id, |j| j.status = JobStatus::Running);
            let result = search.embed_pending(llm.as_ref(), Some(&model)).await;
            jobs.update(&job_id, |j| match &result {
                Ok(n) => {
                    tracing::info!("embedded {n} note(s)");
                    j.status = JobStatus::Completed;
                    j.stage = JobStage::Done;
                }
                Err(e) => {
                    j.status = JobStatus::Failed;
                    j.error = Some(e.to_string());
                }
            });
            flag.store(false, Ordering::SeqCst);
        });
    }

    /// Analyze a transcript synchronously and return the meeting id. Used by the end-to-end
    /// smoke test and any caller that wants to await completion rather than poll a job.
    pub async fn process_transcript_blocking(
        &self,
        title: Option<String>,
        transcript: Transcript,
    ) -> anyhow::Result<MeetingId> {
        let (job_id, cancel) = self.jobs.create(JobKind::Process);
        let id = self
            .orchestrator
            .process(
                &job_id,
                MeetingInput::Transcript { title, transcript },
                &self.events,
                &cancel,
            )
            .await?;
        Ok(id)
    }

    /// Run the full deterministic-prep + two-pass AI analysis on a transcript and return the
    /// Meeting IR and rendered Markdown — without storage or events. Used by the example and the
    /// end-to-end smoke test to inspect intermediate results.
    pub async fn analyze_transcript(
        &self,
        title: Option<String>,
        transcript: &Transcript,
    ) -> anyhow::Result<(MeetingIr, String)> {
        let prepared = crate::preprocess::prepare(transcript, &self.config.chunking);
        let context = AnalysisContext {
            title: title.clone(),
        };
        let ir = crate::ai::analyze(self.ai.as_ref(), &prepared, &context).await?;
        let markdown = markdown::render_with_title(&ir, title.as_deref().unwrap_or("Meeting"));
        Ok((ir, markdown))
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    /// The persistence layer. Exposed for callers/tests that need to seed or inspect stored state
    /// directly (the IPC surface remains the app's only path).
    pub fn store(&self) -> Arc<dyn Store> {
        self.store.clone()
    }
}

/// Boot the engine and serve IPC until a shutdown signal (Ctrl-C) arrives.
///
/// Startup sequence: load config → init logging → init storage/providers/pipeline → start IPC →
/// wait for shutdown.
pub async fn run() -> anyhow::Result<()> {
    let config = Config::from_env();
    init_logging(&config);

    tracing::info!(
        llm_model = %config.ollama.model,
        asr_provider = ?config.asr.provider,
        data_dir = %config.data_dir.display(),
        ipc = %config.ipc_addr,
        "starting notely-engine (protocol v{PROTOCOL_VERSION})"
    );

    let engine = Arc::new(Engine::new(config)?);

    // Recover any capture interrupted mid-enrichment by a previous crash/exit: the source is safe,
    // so we mark it deferred (retryable) rather than leaving it stuck in "processing".
    engine.recover_interrupted().await;
    // Requeue any persisted jobs that were in flight when the process died.
    engine.recover_jobs().await;

    // Best-effort runtime probe (non-fatal): the app can still browse stored meetings offline.
    match engine.llm.health().await {
        Ok(()) => tracing::info!("LLM runtime reachable"),
        Err(e) => {
            tracing::warn!("LLM runtime not reachable: {e} (processing will fail until it is)")
        }
    }

    let server = ipc::Server::new(engine.clone());
    let addr = engine.config().ipc_addr;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("IPC listening on {addr}");

    server.serve(listener, shutdown_signal()).await?;
    tracing::info!("shutdown complete");
    Ok(())
}

fn init_logging(config: &Config) {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| config.log_level.clone().into());
    // `try_init` so tests (which may init logging) don't panic on a second call.
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();
}

/// Resolves when the process is asked to shut down (Ctrl-C).
async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

/// Build a fresh job id (exposed for callers that pre-allocate ids).
pub fn new_job_id() -> JobId {
    JobId::new()
}

/// Convenience alias mirroring the domain constructor, used by binaries/tests.
pub fn new_meeting(title: impl Into<String>) -> Meeting {
    Meeting::new(title)
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    use crate::pipeline::{Job, JobId};
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    fn test_config() -> Config {
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let data_dir = std::env::temp_dir().join(format!(
            "notely-engine-recovery-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, AtomicOrdering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&data_dir);
        Config {
            data_dir,
            ..Config::default()
        }
    }

    fn running_job(kind: JobKind, meeting_id: Option<MeetingId>) -> Job {
        Job {
            id: JobId::new(),
            kind,
            status: JobStatus::Running,
            stage: JobStage::Extraction,
            meeting_id,
            error: None,
            attempts: 0,
        }
    }

    #[tokio::test]
    async fn recover_jobs_requeues_resumable_and_closes_unresumable() {
        let cfg = test_config();
        let data_dir = cfg.data_dir.clone();
        let engine = Engine::new(cfg).unwrap();

        // A meeting whose transcript is safely stored → the interrupted job is resumable.
        let meeting = Meeting::new("Recoverable");
        engine.store.save_meeting(&meeting).await.unwrap();
        engine
            .store
            .save_transcript(&meeting.id, &Transcript::default())
            .await
            .unwrap();

        let store = engine.jobs.store().expect("persistent job store");
        let resumable = running_job(JobKind::Process, Some(meeting.id.clone()));
        store.upsert(&resumable).unwrap();
        // A job pointing at a meeting with no stored transcript → not resumable.
        let orphan = running_job(JobKind::Reprocess, Some(MeetingId::new()));
        store.upsert(&orphan).unwrap();

        let requeued = engine.recover_jobs().await;
        assert_eq!(requeued, 1, "only the job with a stored transcript resumes");

        // The orphan was closed (moved to a terminal state), so it no longer counts as unfinished.
        // The resumed job is re-queued with attempts bumped, tracked in the registry.
        let resumed = engine.jobs.get(&resumable.id).expect("resumed job tracked");
        assert_eq!(resumed.attempts, 1);
        assert_eq!(resumed.kind, JobKind::Reprocess);

        let _ = std::fs::remove_dir_all(&data_dir);
    }

    #[tokio::test]
    async fn recover_jobs_gives_up_after_retry_budget() {
        let cfg = test_config();
        let data_dir = cfg.data_dir.clone();
        let engine = Engine::new(cfg).unwrap();

        let meeting = Meeting::new("Exhausted");
        engine.store.save_meeting(&meeting).await.unwrap();
        engine
            .store
            .save_transcript(&meeting.id, &Transcript::default())
            .await
            .unwrap();

        let store = engine.jobs.store().unwrap();
        let mut exhausted = running_job(JobKind::Reprocess, Some(meeting.id.clone()));
        exhausted.attempts = 3; // already at MAX_JOB_ATTEMPTS
        store.upsert(&exhausted).unwrap();

        let requeued = engine.recover_jobs().await;
        assert_eq!(requeued, 0, "a job past its retry budget is not requeued");
        assert!(
            store.list_unfinished().unwrap().is_empty(),
            "it is closed, not left dangling"
        );

        let _ = std::fs::remove_dir_all(&data_dir);
    }
}
