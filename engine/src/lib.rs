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
pub mod renderer;
pub mod storage;

use std::sync::Arc;

use tokio::sync::broadcast;

use crate::ai::LlmAiEngine;
use crate::asr::WhisperProvider;
use crate::config::Config;
use crate::domain::{Meeting, MeetingId, Transcript};
use crate::ipc::events::Event;
use crate::ipc::protocol::{HealthInfo, ProcessInput, Request, Response, PROTOCOL_VERSION};
use crate::llm::{LlmProvider, OllamaProvider};
use crate::media::FfmpegMediaProcessor;
use crate::pipeline::jobs::JobId;
use crate::pipeline::{JobRegistry, MeetingInput, Orchestrator};
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
    jobs: JobRegistry,
    orchestrator: Orchestrator,
    events: broadcast::Sender<Event>,
}

impl Engine {
    /// Initialize storage and providers from configuration and wire up the pipeline.
    pub fn new(config: Config) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&config.data_dir)?;
        let store: Arc<dyn Store> = Arc::new(SqliteStore::open(config.database_path())?);
        let llm: Arc<dyn LlmProvider> = Arc::new(OllamaProvider::new(&config.ollama)?);

        let media = Arc::new(FfmpegMediaProcessor::new());
        let asr = Arc::new(WhisperProvider);
        let ai = Arc::new(LlmAiEngine::new(llm.clone()));
        let jobs = JobRegistry::new();
        let (events, _rx) = broadcast::channel(EVENT_CHANNEL_CAPACITY);

        let orchestrator = Orchestrator::new(
            media,
            asr,
            ai,
            store.clone(),
            jobs.clone(),
            config.data_dir.clone(),
        );

        Ok(Self {
            config,
            store,
            llm,
            jobs,
            orchestrator,
            events,
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
        }
    }

    async fn health(&self) -> HealthInfo {
        let llm_ok = self.llm.health().await.is_ok();
        HealthInfo {
            protocol_version: PROTOCOL_VERSION,
            engine_ok: true,
            llm_ok,
            model: self.config.ollama.model.clone(),
        }
    }

    /// Create a job and spawn the pipeline; return the job id immediately.
    fn start_processing(&self, input: ProcessInput) -> Response {
        let (job_id, cancel) = self.jobs.create();
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

    /// Analyze a transcript synchronously and return the meeting id. Used by the end-to-end
    /// smoke test and any caller that wants to await completion rather than poll a job.
    pub async fn process_transcript_blocking(
        &self,
        title: Option<String>,
        transcript: Transcript,
    ) -> anyhow::Result<MeetingId> {
        let (job_id, cancel) = self.jobs.create();
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

    pub fn config(&self) -> &Config {
        &self.config
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
        model = %config.ollama.model,
        data_dir = %config.data_dir.display(),
        ipc = %config.ipc_addr,
        "starting notely-engine (protocol v{PROTOCOL_VERSION})"
    );

    let engine = Arc::new(Engine::new(config)?);

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
