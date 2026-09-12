//! Orchestrator tests using fakes for every provider, verifying that stages run in the correct
//! order — and that the transcript path skips media + ASR. No Ollama, FFmpeg, or DB required.

use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use notely_engine::ai::provider::{AiAnalyzer, AiError, AnalysisContext};
use notely_engine::asr::provider::{AsrError, AsrProvider, AudioInput};
use notely_engine::domain::{Meeting, MeetingId, MeetingIr, Transcript, TranscriptSegment};
use notely_engine::media::{ExtractOptions, MediaError, MediaInfo, MediaProcessor, PreparedAudio};
use notely_engine::pipeline::{JobRegistry, MeetingInput, Orchestrator};
use notely_engine::storage::{StorageError, Store};

/// Shared ordered log of calls across all fakes.
type Calls = Arc<Mutex<Vec<String>>>;

fn record(calls: &Calls, what: &str) {
    calls.lock().unwrap().push(what.to_string());
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
            segments: vec![TranscriptSegment {
                speaker_id: Some("S1".into()),
                start: 0.0,
                end: 1.0,
                text: "from asr".into(),
                language: None,
            }],
        })
    }
}

struct FakeAi(Calls);
#[async_trait]
impl AiAnalyzer for FakeAi {
    async fn analyze(
        &self,
        _transcript: &Transcript,
        _context: &AnalysisContext,
    ) -> Result<MeetingIr, AiError> {
        record(&self.0, "ai.analyze");
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
    );
    (orch, jobs)
}

#[tokio::test]
async fn audio_input_runs_media_then_asr_then_ai_then_render_store() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create();
    let (events, _rx) = tokio::sync::broadcast::channel(16);

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
    // Media → ASR → (transcript saved) → AI → (IR saved) → MOM saved.
    let media = log.iter().position(|c| c == "media.extract_audio").unwrap();
    let asr = log.iter().position(|c| c == "asr.transcribe").unwrap();
    let save_t = log
        .iter()
        .position(|c| c == "store.save_transcript")
        .unwrap();
    let ai = log.iter().position(|c| c == "ai.analyze").unwrap();
    let save_ir = log
        .iter()
        .position(|c| c == "store.save_meeting_ir")
        .unwrap();
    let save_mom = log.iter().position(|c| c == "store.save_mom").unwrap();
    assert!(media < asr, "media before asr");
    assert!(asr < save_t, "asr before transcript save");
    assert!(save_t < ai, "transcript saved before analysis");
    assert!(ai < save_ir, "analysis before IR save");
    assert!(save_ir < save_mom, "IR saved before MOM save");
}

#[tokio::test]
async fn transcript_input_skips_media_and_asr() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create();
    let (events, _rx) = tokio::sync::broadcast::channel(16);

    let transcript = Transcript {
        segments: vec![TranscriptSegment {
            speaker_id: Some("S1".into()),
            start: 0.0,
            end: 1.0,
            text: "provided".into(),
            language: None,
        }],
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
        "media must be skipped: {log:?}"
    );
    assert!(
        !log.iter().any(|c| c.starts_with("asr")),
        "asr must be skipped: {log:?}"
    );
    assert!(log.iter().any(|c| c == "ai.analyze"));
    assert!(log.iter().any(|c| c == "store.save_mom"));
}

#[tokio::test]
async fn cancellation_before_run_stops_the_pipeline() {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let (orch, jobs) = orchestrator(&calls);
    let (job_id, cancel) = jobs.create();
    cancel.cancel(); // cancel up-front
    let (events, _rx) = tokio::sync::broadcast::channel(16);

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
        !log.iter().any(|c| c == "ai.analyze"),
        "analysis must not run after cancel: {log:?}"
    );
}
