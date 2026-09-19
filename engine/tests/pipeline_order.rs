//! Orchestrator tests using fakes for every provider, verifying the full stage order —
//! media → ASR → chunking → extraction → synthesis → render/store — and that the transcript path
//! skips media + ASR. No Ollama, ASR runtime, FFmpeg, or DB required.

use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use notely_engine::ai::provider::{AiAnalyzer, AiError, AnalysisContext};
use notely_engine::ai::ChunkFindings;
use notely_engine::asr::provider::{AsrError, AsrProvider, AudioInput};
use notely_engine::config::ChunkingConfig;
use notely_engine::domain::{
    Meeting, MeetingId, MeetingIr, ProcessingStatus, Transcript, TranscriptSegment,
};
use notely_engine::media::{ExtractOptions, MediaError, MediaInfo, MediaProcessor, PreparedAudio};
use notely_engine::pipeline::{JobRegistry, MeetingInput, Orchestrator};
use notely_engine::preprocess::Chunk;
use notely_engine::storage::{StorageError, Store};

type Calls = Arc<Mutex<Vec<String>>>;

fn record(calls: &Calls, what: &str) {
    calls.lock().unwrap().push(what.to_string());
}

fn seg(text: &str) -> TranscriptSegment {
    TranscriptSegment {
        speaker_id: Some("S1".into()),
        start: 0.0,
        end: 1.0,
        text: text.to_string(),
        language: None,
        confidence: None,
    }
}

struct FakeMedia(Calls);
#[async_trait]
impl MediaProcessor for FakeMedia {
    async fn probe(&self, _input: &Path) -> Result<MediaInfo, MediaError> {
        record(&self.0, "media.probe");
        Ok(MediaInfo::default())
    }
    async fn extract_audio(
        &self,
        _input: &Path,
        _out_dir: &Path,
        _options: &ExtractOptions,
    ) -> Result<PreparedAudio, MediaError> {
        record(&self.0, "media.extract_audio");
        Ok(PreparedAudio {
            path: "/tmp/fake.wav".into(),
            sample_rate: 16_000,
            channels: 1,
        })
    }
}

struct FakeAsr(Calls);
#[async_trait]
impl AsrProvider for FakeAsr {
    fn name(&self) -> &'static str {
        "fake"
    }
    async fn transcribe(&self, _audio: &AudioInput) -> Result<Transcript, AsrError> {
        record(&self.0, "asr.transcribe");
        Ok(Transcript {
            segments: vec![seg("from asr")],
        })
    }
}

struct FakeAi(Calls);
#[async_trait]
impl AiAnalyzer for FakeAi {
    async fn extract_chunk(
        &self,
        _chunk: &Chunk,
        _context: &AnalysisContext,
    ) -> Result<ChunkFindings, AiError> {
        record(&self.0, "ai.extract_chunk");
        Ok(ChunkFindings::default())
    }
    async fn synthesize(
        &self,
        _findings: &[ChunkFindings],
        _transcript: &Transcript,
        _context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError> {
        record(&self.0, "ai.synthesize");
        Ok(MeetingIr {
            summary: "fake summary".into(),
            ..Default::default()
        })
    }
}

struct FakeStore(Calls);
#[async_trait]
impl Store for FakeStore {
    async fn save_meeting(&self, _m: &Meeting) -> Result<(), StorageError> {
        record(&self.0, "store.save_meeting");
        Ok(())
    }
    async fn get_meeting(&self, _id: &MeetingId) -> Result<Option<Meeting>, StorageError> {
        Ok(None)
    }
    async fn list_meetings(&self) -> Result<Vec<Meeting>, StorageError> {
        Ok(vec![])
    }
    async fn save_transcript(&self, _id: &MeetingId, _t: &Transcript) -> Result<(), StorageError> {
        record(&self.0, "store.save_transcript");
        Ok(())
    }
    async fn get_transcript(&self, _id: &MeetingId) -> Result<Option<Transcript>, StorageError> {
        Ok(None)
    }
    async fn save_meeting_ir(&self, _id: &MeetingId, _ir: &MeetingIr) -> Result<(), StorageError> {
        record(&self.0, "store.save_meeting_ir");
        Ok(())
    }
    async fn get_meeting_ir(&self, _id: &MeetingId) -> Result<Option<MeetingIr>, StorageError> {
        Ok(None)
    }
    async fn save_mom(&self, _id: &MeetingId, _mom: &str) -> Result<(), StorageError> {
        record(&self.0, "store.save_mom");
        Ok(())
    }
    async fn get_mom(&self, _id: &MeetingId) -> Result<Option<String>, StorageError> {
        Ok(None)
    }
    async fn save_processing_status(
        &self,
        _id: &MeetingId,
        _status: &ProcessingStatus,
    ) -> Result<(), StorageError> {
        record(&self.0, "store.save_processing_status");
        Ok(())
    }
    async fn get_processing_status(
        &self,
        _id: &MeetingId,
    ) -> Result<Option<ProcessingStatus>, StorageError> {
        Ok(None)
    }
    async fn list_processing_statuses(
        &self,
    ) -> Result<Vec<(MeetingId, ProcessingStatus)>, StorageError> {
        Ok(vec![])
    }
}

fn orchestrator(calls: &Calls) -> (Orchestrator, JobRegistry) {
    let jobs = JobRegistry::new();
    let orch = Orchestrator::new(
        Arc::new(FakeMedia(calls.clone())),
        Arc::new(FakeAsr(calls.clone())),
        Arc::new(FakeAi(calls.clone())),
        Arc::new(FakeStore(calls.clone())),
        jobs.clone(),
        std::env::temp_dir(),
        ChunkingConfig::default(),
    );
    (orch, jobs)
}

fn pos(log: &[String], needle: &str) -> usize {
    log.iter()
        .position(|c| c == needle)
        .unwrap_or_else(|| panic!("missing call: {needle} in {log:?}"))
}

#[tokio::test]
async fn audio_input_runs_media_asr_chunk_extract_synthesize_then_store() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create(notely_engine::pipeline::JobKind::Process);
    let (events, _rx) = tokio::sync::broadcast::channel(64);

    orch.process(
        &job_id,
        MeetingInput::Audio {
            title: Some("Sync".into()),
            path: "/tmp/in.m4a".into(),
        },
        &events,
        &cancel,
    )
    .await
    .expect("pipeline succeeds");

    let log = calls.lock().unwrap().clone();
    let media = pos(&log, "media.extract_audio");
    let asr = pos(&log, "asr.transcribe");
    let save_t = pos(&log, "store.save_transcript");
    let extract = pos(&log, "ai.extract_chunk");
    let synth = pos(&log, "ai.synthesize");
    let save_ir = pos(&log, "store.save_meeting_ir");
    let save_mom = pos(&log, "store.save_mom");
    assert!(media < asr, "media before asr");
    assert!(asr < save_t, "asr before transcript save");
    assert!(
        save_t < extract,
        "transcript saved (then chunked) before extraction"
    );
    assert!(extract < synth, "extraction before synthesis");
    assert!(synth < save_ir, "synthesis before IR save");
    assert!(save_ir < save_mom, "IR saved before MOM save");
}

#[tokio::test]
async fn transcribe_one_runs_only_media_and_asr_no_job_or_persistence() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, _jobs) = orchestrator(&calls);

    let transcript = orch
        .transcribe_one(std::path::Path::new("/tmp/chunk.m4a"))
        .await
        .expect("chunk transcribes");

    // Returns the ASR output...
    assert!(
        !transcript.segments.is_empty(),
        "returns the ASR transcript"
    );
    // ...and touches ONLY media + ASR — no chunking/AI/store (no job, no events, no persistence).
    let log = calls.lock().unwrap().clone();
    assert_eq!(log, vec!["media.extract_audio", "asr.transcribe"]);
}

#[tokio::test]
async fn transcript_input_skips_media_and_asr_but_still_extracts_and_synthesizes() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create(notely_engine::pipeline::JobKind::Process);
    let (events, _rx) = tokio::sync::broadcast::channel(64);

    let transcript = Transcript {
        segments: vec![seg("provided")],
    };
    orch.process(
        &job_id,
        MeetingInput::Transcript {
            title: None,
            transcript,
        },
        &events,
        &cancel,
    )
    .await
    .expect("pipeline succeeds");

    let log = calls.lock().unwrap().clone();
    assert!(
        !log.iter().any(|c| c.starts_with("media")),
        "media skipped: {log:?}"
    );
    assert!(
        !log.iter().any(|c| c.starts_with("asr")),
        "asr skipped: {log:?}"
    );
    assert!(log.iter().any(|c| c == "ai.extract_chunk"));
    assert!(log.iter().any(|c| c == "ai.synthesize"));
    assert!(log.iter().any(|c| c == "store.save_mom"));
}

#[tokio::test]
async fn cancellation_before_run_stops_the_pipeline() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create(notely_engine::pipeline::JobKind::Process);
    cancel.cancel();
    let (events, _rx) = tokio::sync::broadcast::channel(64);

    let result = orch
        .process(
            &job_id,
            MeetingInput::Transcript {
                title: None,
                transcript: Transcript::default(),
            },
            &events,
            &cancel,
        )
        .await;

    assert!(result.is_err(), "cancelled run should error");
    let log = calls.lock().unwrap().clone();
    assert!(
        !log.iter().any(|c| c == "ai.extract_chunk"),
        "no extraction after cancel: {log:?}"
    );
}
