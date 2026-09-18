//! Ollama-backed [`LlmProvider`] — the v0 target runtime.
//!
//! This is the ONLY module that knows Ollama's HTTP API exists. It talks to a local Ollama
//! server's `/api/generate` (non-streaming) endpoint. Request-body construction is factored into
//! [`build_generate_body`] so it can be unit-tested without a running Ollama.

use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::OllamaConfig;

use super::provider::{
    EmbedRequest, EmbedResponse, GenerateRequest, GenerateResponse, LlmError, LlmProvider,
};

/// Talks to a local Ollama instance.
pub struct OllamaProvider {
    client: reqwest::Client,
    base_url: String,
    default_model: String,
}

impl OllamaProvider {
    /// Build a provider from configuration.
    pub fn new(config: &OllamaConfig) -> Result<Self, LlmError> {
        let client = reqwest::Client::builder()
            .timeout(config.timeout)
            .build()
            .map_err(|e| LlmError::Transport(e.to_string()))?;
        Ok(Self {
            client,
            base_url: config.base_url.trim_end_matches('/').to_string(),
            default_model: config.model.clone(),
        })
    }

    fn model_for<'a>(&'a self, request: &'a GenerateRequest) -> &'a str {
        request.model.as_deref().unwrap_or(&self.default_model)
    }
}

/// Ollama's `/api/generate` response (non-streaming). We only need `response`.
#[derive(Debug, Deserialize)]
struct OllamaGenerateResponse {
    #[serde(default)]
    response: String,
    #[serde(default)]
    model: String,
    #[serde(default)]
    error: Option<String>,
}

/// Ollama's `/api/embed` response. `embeddings` is one vector per input.
#[derive(Debug, Deserialize)]
struct OllamaEmbedResponse {
    #[serde(default)]
    embeddings: Vec<Vec<f32>>,
    #[serde(default)]
    model: String,
    #[serde(default)]
    error: Option<String>,
}

/// Construct the JSON body for `/api/embed`. Pure and deterministic — unit-tested below.
pub fn build_embed_body(model: &str, input: &[String]) -> Value {
    json!({
        "model": model,
        "input": input,
    })
}

/// Construct the JSON body for `/api/generate`. Pure and deterministic — unit-tested below.
pub fn build_generate_body(model: &str, request: &GenerateRequest) -> Value {
    let mut body = json!({
        "model": model,
        "prompt": request.prompt,
        "stream": false,
        "think": request.think,
    });

    if let Some(system) = &request.system {
        body["system"] = json!(system);
    }
    if let Some(format) = &request.format {
        body["format"] = format.clone();
    }

    let mut options = serde_json::Map::new();
    if let Some(t) = request.config.temperature {
        options.insert("temperature".into(), json!(t));
    }
    if let Some(n) = request.config.num_ctx {
        options.insert("num_ctx".into(), json!(n));
    }
    if let Some(m) = request.config.max_tokens {
        options.insert("num_predict".into(), json!(m));
    }
    if !options.is_empty() {
        body["options"] = Value::Object(options);
    }

    body
}

#[async_trait::async_trait]
impl LlmProvider for OllamaProvider {
    async fn generate(&self, request: GenerateRequest) -> Result<GenerateResponse, LlmError> {
        let model = self.model_for(&request).to_string();
        let body = build_generate_body(&model, &request);
        let url = format!("{}/api/generate", self.base_url);

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| LlmError::Transport(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(LlmError::Runtime(format!("HTTP {status}: {text}")));
        }

        let parsed: OllamaGenerateResponse = resp
            .json()
            .await
            .map_err(|e| LlmError::Decode(e.to_string()))?;

        if let Some(err) = parsed.error {
            return Err(LlmError::Runtime(err));
        }

        Ok(GenerateResponse {
            text: parsed.response,
            model: if parsed.model.is_empty() {
                model
            } else {
                parsed.model
            },
        })
    }

    async fn health(&self) -> Result<(), LlmError> {
        let url = format!("{}/api/tags", self.base_url);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| LlmError::Transport(e.to_string()))?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(LlmError::Runtime(format!("HTTP {}", resp.status())))
        }
    }

    async fn embed(&self, request: EmbedRequest) -> Result<EmbedResponse, LlmError> {
        if request.input.is_empty() {
            return Ok(EmbedResponse {
                vectors: Vec::new(),
                model: request.model.unwrap_or_else(|| self.default_model.clone()),
            });
        }
        let model = request
            .model
            .clone()
            .unwrap_or_else(|| self.default_model.clone());
        let body = build_embed_body(&model, &request.input);
        let url = format!("{}/api/embed", self.base_url);

        let resp = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| LlmError::Transport(e.to_string()))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(LlmError::Runtime(format!("HTTP {status}: {text}")));
        }

        let parsed: OllamaEmbedResponse = resp
            .json()
            .await
            .map_err(|e| LlmError::Decode(e.to_string()))?;

        if let Some(err) = parsed.error {
            return Err(LlmError::Runtime(err));
        }

        Ok(EmbedResponse {
            vectors: parsed.embeddings,
            model: if parsed.model.is_empty() {
                model
            } else {
                parsed.model
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::provider::GenerateRequest;

    #[test]
    fn body_includes_core_fields_and_disables_streaming() {
        let req = GenerateRequest::new("hello").with_system("be terse");
        let body = build_generate_body("qwen3:4b", &req);
        assert_eq!(body["model"], "qwen3:4b");
        assert_eq!(body["prompt"], "hello");
        assert_eq!(body["system"], "be terse");
        assert_eq!(body["stream"], false);
        assert_eq!(body["think"], false);
        // No options unless configured.
        assert!(body.get("options").is_none());
        // No format unless requested.
        assert!(body.get("format").is_none());
    }

    #[test]
    fn body_includes_format_and_options_when_set() {
        let schema = json!({"type": "object"});
        let req = GenerateRequest::new("extract")
            .with_format(schema.clone())
            .with_temperature(0.2);
        let body = build_generate_body("qwen3:4b", &req);
        assert_eq!(body["format"], schema);
        let temp = body["options"]["temperature"].as_f64().unwrap();
        assert!((temp - 0.2).abs() < 1e-6, "temperature was {temp}");
    }

    #[test]
    fn embed_body_carries_model_and_batch_input() {
        let body = build_embed_body("nomic-embed-text", &["a".into(), "b".into()]);
        assert_eq!(body["model"], "nomic-embed-text");
        assert_eq!(body["input"][0], "a");
        assert_eq!(body["input"][1], "b");
    }
}
