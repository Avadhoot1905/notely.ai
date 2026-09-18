//! Reliability coverage for the core promise: **AI can fail; the user's capture cannot be lost.**
//!
//! These tests exercise the orchestrator against an in-memory store with a toggleable AI, plus the
//! engine's startup recovery and retry paths, proving that a capture's source (transcript) survives
//! AI failure, that retry is idempotent (no duplicate meetings), and that an interrupted capture is
//! recovered as retryable rather than lost.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use notely_engine::ai::provider::{AiAnalyzer, AiError, AnalysisContext};
use notely_engine::ai::ChunkFindings;
use notely_engine::asr::provider::{AsrError, AsrProvider, AudioInput};
use notely_engine::config::{ChunkingConfig, Config};
use notely_engine::domain::{
    Meeting, MeetingId, MeetingIr, ProcessingState, ProcessingStatus, Transcript, TranscriptSegment,
};
use notely_engine::ipc::protocol::{Request, Response};
use notely_engine::llm::LlmError;
use notely_engine::media::{ExtractOptions, MediaError, MediaInfo, MediaProcessor, PreparedAudio};
use notely_engine::pipeline::{JobRegistry, MeetingInput, Orchestrator};
use notely_engine::preprocess::Chunk;
use notely_engine::storage::{StorageError, Store};
use notely_engine::Engine;

// ---------------------------------------------------------------------------
// In-memory store with inspectable state and an optional IR-save failure.
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Inner {
    meetings: HashMap<String, Meeting>,
    transcripts: HashMap<String, Transcript>,
    irs: HashMap<String, MeetingIr>,
    moms: HashMap<String, String>,
    statuses: HashMap<String, ProcessingStatus>,
    fail_ir: bool,
}

#[derive(Clone, Default)]
struct MemStore(Arc<Mutex<Inner>>);

impl MemStore {
    fn with_ir_failure() -> Self {
        let s = Self::default();
        s.0.lock().unwrap().fail_ir = true;
        s
    }
    fn meeting_count(&self) -> usize {
        self.0.lock().unwrap().meetings.len()
    }
    fn status(&self, id: &MeetingId) -> Option<ProcessingStatus> {
        self.0.lock().unwrap().statuses.get(&id.0).cloned()
    }
    fn has_ir(&self, id: &MeetingId) -> bool {
        self.0.lock().unwrap().irs.contains_key(&id.0)
    }
    fn has_transcript(&self, id: &MeetingId) -> bool {
        self.0.lock().unwrap().transcripts.contains_key(&id.0)
    }
}

#[async_trait]
impl Store for MemStore {
    async fn save_meeting(&self, m: &Meeting) -> Result<(), StorageError> {
        self.0
            .lock()
            .unwrap()
            .meetings
            .insert(m.id.0.clone(), m.clone());
        Ok(())
    }
    async fn get_meeting(&self, id: &MeetingId) -> Result<Option<Meeting>, StorageError> {
        Ok(self.0.lock().unwrap().meetings.get(&id.0).cloned())
    }
    async fn list_meetings(&self) -> Result<Vec<Meeting>, StorageError> {
        Ok(self.0.lock().unwrap().meetings.values().cloned().collect())
    }
    async fn save_transcript(&self, id: &MeetingId, t: &Transcript) -> Result<(), StorageError> {
        self.0
            .lock()
            .unwrap()
            .transcripts
            .insert(id.0.clone(), t.clone());
        Ok(())
    }
    async fn get_transcript(&self, id: &MeetingId) -> Result<Option<Transcript>, StorageError> {
        Ok(self.0.lock().unwrap().transcripts.get(&id.0).cloned())
    }
    async fn save_meeting_ir(&self, id: &MeetingId, ir: &MeetingIr) -> Result<(), StorageError> {
        let mut inner = self.0.lock().unwrap();
        if inner.fail_ir {
            return Err(StorageError::Backend("simulated IR write failure".into()));
        }
        inner.irs.insert(id.0.clone(), ir.clone());
        Ok(())
    }
    async fn get_meeting_ir(&self, id: &MeetingId) -> Result<Option<MeetingIr>, StorageError> {
        Ok(self.0.lock().unwrap().irs.get(&id.0).cloned())
    }
    async fn save_mom(&self, id: &MeetingId, mom: &str) -> Result<(), StorageError> {
        self.0
            .lock()
            .unwrap()
            .moms
            .insert(id.0.clone(), mom.to_string());
        Ok(())
    }
    async fn get_mom(&self, id: &MeetingId) -> Result<Option<String>, StorageError> {
        Ok(self.0.lock().unwrap().moms.get(&id.0).cloned())
    }
    async fn save_processing_status(
        &self,
        id: &MeetingId,
        status: &ProcessingStatus,
    ) -> Result<(), StorageError> {
        self.0
            .lock()
            .unwrap()
            .statuses
            .insert(id.0.clone(), status.clone());
        Ok(())
    }
    async fn get_processing_status(
        &self,
        id: &MeetingId,
    ) -> Result<Option<ProcessingStatus>, StorageError> {
        Ok(self.0.lock().unwrap().statuses.get(&id.0).cloned())
    }
    async fn list_processing_statuses(
        &self,
    ) -> Result<Vec<(MeetingId, ProcessingStatus)>, StorageError> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .statuses
            .iter()
            .map(|(k, v)| (MeetingId(k.clone()), v.clone()))
            .collect())
    }
}

// ---------------------------------------------------------------------------
// Providers: media/ASR are inert; the AI can be toggled to fail (LLM "offline").
// ---------------------------------------------------------------------------

struct FakeMedia;
#[async_trait]
impl MediaProcessor for FakeMedia {
    async fn probe(&self, _input: &std::path::Path) -> Result<MediaInfo, MediaError> {
        Ok(MediaInfo::default())
    }
    async fn extract_audio(
        &self,
        _input: &std::path::Path,
        _out_dir: &std::path::Path,
        _options: &ExtractOptions,
    ) -> Result<PreparedAudio, MediaError> {
        Ok(PreparedAudio {
            path: "/tmp/fake.wav".into(),
            sample_rate: 16_000,
            channels: 1,
        })
    }
}

struct FakeAsr;
#[async_trait]
impl AsrProvider for FakeAsr {
    fn name(&self) -> &'static str {
        "fake"
    }
    async fn transcribe(&self, _audio: &AudioInput) -> Result<Transcript, AsrError> {
        Ok(Transcript::default())
    }
}

/// AI that fails while `down` is set (simulating an unavailable LLM), and succeeds otherwise.
#[derive(Clone)]
struct ToggleAi {
    down: Arc<AtomicBool>,
}
impl ToggleAi {
    fn new(down: bool) -> Self {
        Self {
            down: Arc::new(AtomicBool::new(down)),
        }
    }
    fn set_down(&self, v: bool) {
        self.down.store(v, Ordering::SeqCst);
    }
}
#[async_trait]
impl AiAnalyzer for ToggleAi {
    async fn extract_chunk(
        &self,
        _chunk: &Chunk,
        _context: &AnalysisContext,
    ) -> Result<ChunkFindings, AiError> {
        if self.down.load(Ordering::SeqCst) {
            return Err(AiError::Llm(LlmError::Transport("offline".into())));
        }
        Ok(ChunkFindings::default())
    }
    async fn synthesize(
        &self,
        _findings: &[ChunkFindings],
        _transcript: &Transcript,
        _context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError> {
        if self.down.load(Ordering::SeqCst) {
            return Err(AiError::Llm(LlmError::Transport("offline".into())));
        }
        Ok(MeetingIr {
            summary: "recovered summary".into(),
            ..Default::default()
        })
    }
}

fn transcript() -> Transcript {
    Transcript {
        segments: vec![TranscriptSegment {
            speaker_id: Some("S1".into()),
            start: 0.0,
            end: 1.0,
            text: "We chose PostgreSQL for Project X.".into(),
            language: None,
            confidence: None,
        }],
    }
}

fn orchestrator(store: MemStore, ai: ToggleAi) -> (Orchestrator, JobRegistry) {
    let jobs = JobRegistry::new();
    let orch = Orchestrator::new(
        Arc::new(FakeMedia),
        Arc::new(FakeAsr),
        Arc::new(ai),
        Arc::new(store),
        jobs.clone(),
        std::env::temp_dir(),
        ChunkingConfig::default(),
    );
    (orch, jobs)
}

async fn process_transcript(orch: &Orchestrator, jobs: &JobRegistry) -> Result<MeetingId, ()> {
    let (job_id, cancel) = jobs.create(notely_engine::pipeline::JobKind::Process);
    let (events, _rx) = tokio::sync::broadcast::channel(64);
    orch.process(
        &job_id,
        MeetingInput::Transcript {
            title: Some("Project X".into()),
            transcript: transcript(),
        },
        &events,
        &cancel,
    )
    .await
    .map_err(|_| ())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn ai_failure_preserves_source_and_defers() {
    let store = MemStore::default();
    let (orch, jobs) = orchestrator(store.clone(), ToggleAi::new(true)); // AI down

    let result = process_transcript(&orch, &jobs).await;
    assert!(result.is_err(), "processing fails when AI is down");

    // Exactly one capture exists, and its SOURCE is safe even though enrichment failed.
    assert_eq!(store.meeting_count(), 1);
    let (id, status) = store
        .0
        .lock()
        .unwrap()
        .statuses
        .iter()
        .next()
        .map(|(k, v)| (MeetingId(k.clone()), v.clone()))
        .unwrap();
    assert!(
        store.has_transcript(&id),
        "transcript (the source) is persisted"
    );
    assert!(!store.has_ir(&id), "no derived IR was produced");
    assert_eq!(status.state, ProcessingState::Deferred);
    assert!(status.is_retryable());
}

#[tokio::test]
async fn retry_after_recovery_enriches_without_duplicating() {
    let store = MemStore::default();
    let ai = ToggleAi::new(true); // start down
    let (orch, jobs) = orchestrator(store.clone(), ai.clone());

    // First pass fails → deferred, source safe.
    assert!(process_transcript(&orch, &jobs).await.is_err());
    assert_eq!(store.meeting_count(), 1);
    let id = MeetingId(
        store
            .0
            .lock()
            .unwrap()
            .meetings
            .keys()
            .next()
            .unwrap()
            .clone(),
    );
    assert_eq!(store.status(&id).unwrap().state, ProcessingState::Deferred);

    // AI comes back; retry the SAME meeting.
    ai.set_down(false);
    let (job_id, cancel) = jobs.create(notely_engine::pipeline::JobKind::Process);
    let (events, _rx) = tokio::sync::broadcast::channel(64);
    let out = orch.reprocess(&job_id, &id, &events, &cancel).await;
    assert!(out.is_ok(), "retry succeeds once AI is available");

    // No duplicate capture; enrichment is now present and Ready.
    assert_eq!(
        store.meeting_count(),
        1,
        "retry must not create a second meeting"
    );
    assert!(store.has_ir(&id), "IR produced on retry");
    assert_eq!(store.status(&id).unwrap().state, ProcessingState::Ready);
}

#[tokio::test]
async fn storage_failure_marks_failed_but_keeps_source() {
    let store = MemStore::with_ir_failure(); // IR writes fail (a persistence error)
    let (orch, jobs) = orchestrator(store.clone(), ToggleAi::new(false)); // AI is fine

    assert!(process_transcript(&orch, &jobs).await.is_err());
    let id = MeetingId(
        store
            .0
            .lock()
            .unwrap()
            .meetings
            .keys()
            .next()
            .unwrap()
            .clone(),
    );
    assert!(
        store.has_transcript(&id),
        "source transcript still persisted"
    );
    let status = store.status(&id).unwrap();
    // A persistence failure needs attention rather than blind retry.
    assert_eq!(status.state, ProcessingState::Failed);
    assert!(!status.is_retryable());
}

#[tokio::test]
async fn engine_recovers_interrupted_captures_on_startup() {
    // Real engine over a temp data dir; seed a capture stuck in "processing".
    let dir = std::env::temp_dir().join(format!(
        "notely-recover-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let config = Config {
        data_dir: dir.clone(),
        ..Default::default()
    };
    let engine = Engine::new(config).expect("engine builds");
    let store = engine.store();
    let meeting = Meeting::new("Interrupted");
    store.save_meeting(&meeting).await.unwrap();
    store
        .save_transcript(&meeting.id, &transcript())
        .await
        .unwrap();
    store
        .save_processing_status(&meeting.id, &ProcessingStatus::processing())
        .await
        .unwrap();

    let recovered = engine.recover_interrupted().await;
    assert_eq!(recovered, 1);
    assert_eq!(
        store
            .get_processing_status(&meeting.id)
            .await
            .unwrap()
            .unwrap()
            .state,
        ProcessingState::Deferred,
    );

    // ListMeetings surfaces the capture with its (now deferred) status.
    match engine.dispatch(Request::ListMeetings).await {
        Response::MeetingList(list) => {
            let entry = list.iter().find(|s| s.meeting.id == meeting.id).unwrap();
            assert_eq!(
                entry.status.as_ref().unwrap().state,
                ProcessingState::Deferred
            );
        }
        other => panic!("expected MeetingList, got {other:?}"),
    }

    // A recovery pass is idempotent: a Deferred capture is not re-touched into another state.
    assert_eq!(engine.recover_interrupted().await, 0);

    let _ = std::fs::remove_dir_all(&dir);
}
