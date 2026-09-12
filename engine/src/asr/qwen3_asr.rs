//! Qwen3-ASR provider — the v0 default speech recognition backend.
//!
//! IMPORTANT: Qwen3-ASR is served by a **separate ASR runtime**, NOT by Ollama (Ollama does not do
//! speech-to-text). This provider is an HTTP client for a local Qwen3-ASR inference server. It is
//! the only place that knows that runtime's wire format; the pipeline only sees `AsrProvider`.
//!
//! Runtime contract (configurable via `NOTELY_ASR_URL`, see `models/manifests/qwen3-asr.yaml`):
//!
//! ```text
//! POST {base_url}/v1/transcribe
//!   { "model": "qwen3-asr", "audio_path": "/abs/path/to/audio.wav", "language": "en"? }
//! -> { "language"?: "en",
//!      "text"?: "...",
//!      "segments": [ { "start": f64, "end": f64, "text": "...",
//!                      "speaker"?: "S1", "confidence"?: 0.0..1.0, "language"?: "en" } ] }
//! ```
//!
//! The server is expected to read `audio_path` from the shared local filesystem (this is a
//! local-first, single-machine setup). Speaker labels are used ONLY if the runtime provides them —
//! Notely never fabricates diarization.

use serde::Deserialize;
use serde_json::json;

use crate::config::AsrConfig;
use crate::domain::{Transcript, TranscriptSegment};

use super::provider::{AsrError, AsrProvider, AudioInput};

/// HTTP client for a local Qwen3-ASR runtime.
pub struct Qwen3AsrProvider {
    client: reqwest::Client,
    base_url: String,
    model: String,
}

impl Qwen3AsrProvider {
    pub fn new(config: &AsrConfig) -> Result<Self, AsrError> {
        let client = reqwest::Client::builder()
            .timeout(config.timeout)
            .build()
            .map_err(|e| AsrError::Unreachable(e.to_string()))?;
        Ok(Self {
            client,
            base_url: config.base_url.trim_end_matches('/').to_string(),
            model: config.model.clone(),
        })
    }
}

#[derive(Debug, Deserialize)]
struct AsrResponse {
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    segments: Vec<AsrSegment>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AsrSegment {
    #[serde(default)]
    start: f64,
    #[serde(default)]
    end: f64,
    #[serde(default)]
    text: String,
    /// Only present if the runtime performs diarization. Never invented by Notely.
    #[serde(default)]
    speaker: Option<String>,
    #[serde(default)]
    confidence: Option<f64>,
    #[serde(default)]
    language: Option<String>,
}

/// Map a decoded runtime response into the canonical [`Transcript`]. Pure — unit-tested below.
fn response_to_transcript(resp: AsrResponse) -> Transcript {
    let top_language = resp.language;
    let segments = resp
        .segments
        .into_iter()
        .filter(|s| !s.text.trim().is_empty())
        .map(|s| TranscriptSegment {
            // Preserve speaker ONLY if the runtime provided it; do not fabricate.
            speaker_id: s.speaker,
            start: s.start,
            end: s.end,
            text: s.text.trim().to_string(),
            language: s.language.or_else(|| top_language.clone()),
            confidence: s.confidence,
        })
        .collect();
    Transcript { segments }
}

#[async_trait::async_trait]
impl AsrProvider for Qwen3AsrProvider {
    fn name(&self) -> &'static str {
        "qwen3-asr"
    }

    async fn transcribe(&self, audio: &AudioInput) -> Result<Transcript, AsrError> {
        if !audio.path.exists() {
            return Err(AsrError::InputNotFound(audio.path.clone()));
        }
        let body = json!({
            "model": self.model,
            "audio_path": audio.path.to_string_lossy(),
            "language": audio.language_hint,
        });
        let url = format!("{}/v1/transcribe", self.base_url);

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AsrError::Unreachable(format!("{url}: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(AsrError::Runtime(format!("HTTP {status}: {text}")));
        }

        let parsed: AsrResponse = resp
            .json()
            .await
            .map_err(|e| AsrError::Runtime(e.to_string()))?;
        if let Some(err) = parsed.error {
            return Err(AsrError::Runtime(err));
        }
        Ok(response_to_transcript(parsed))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_segments_preserving_metadata_without_inventing_speakers() {
        let resp: AsrResponse = serde_json::from_value(json!({
            "language": "en",
            "segments": [
                { "start": 0.0, "end": 1.2, "text": "hello", "speaker": "S1", "confidence": 0.9 },
                { "start": 1.2, "end": 2.0, "text": "  " },
                { "start": 2.0, "end": 3.0, "text": "world" }
            ]
        }))
        .unwrap();
        let t = response_to_transcript(resp);
        assert_eq!(t.segments.len(), 2, "empty text dropped");
        assert_eq!(t.segments[0].speaker_id.as_deref(), Some("S1"));
        assert_eq!(t.segments[0].confidence, Some(0.9));
        assert_eq!(t.segments[0].language.as_deref(), Some("en")); // inherits top-level language
                                                                   // No speaker was provided for the second segment -> stays None (not fabricated).
        assert_eq!(t.segments[1].speaker_id, None);
    }
}
