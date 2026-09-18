//! MLX-backed [`LlmProvider`] — an OPTIONAL Apple-Silicon inference path.
//!
//! MLX is **never linked into this process**. Exactly like Ollama and the ASR runtime, MLX runs as
//! a separate local HTTP server (`mlx_lm.server`, which exposes an OpenAI-compatible API); this
//! module is the only place that knows that wire format. Selecting it is opt-in
//! (`NOTELY_LLM_PROVIDER=mlx`); when the server is not running, `generate`/`health` simply return
//! transport errors and the pipeline defers the work — nothing crashes, and Linux/Windows behavior
//! is untouched because they keep the default Ollama runtime.

use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::MlxConfig;

use super::provider::{GenerateRequest, GenerateResponse, LlmError, LlmProvider};

/// Talks to a local MLX-LM HTTP server (OpenAI-compatible).
pub struct MlxProvider {
    client: reqwest::Client,
    base_url: String,
    default_model: String,
}

impl MlxProvider {
    pub fn new(config: &MlxConfig) -> Result<Self, LlmError> {
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

/// OpenAI-compatible chat-completions response (only the fields we need).
#[derive(Debug, Deserialize)]
struct ChatResponse {
    #[serde(default)]
    choices: Vec<Choice>,
    #[serde(default)]
    model: String,
    #[serde(default)]
    error: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    #[serde(default)]
    message: ChoiceMessage,
}

#[derive(Debug, Default, Deserialize)]
struct ChoiceMessage {
    #[serde(default)]
    content: String,
}

/// Construct the JSON body for `/v1/chat/completions`. Pure and deterministic — unit-tested below.
pub fn build_chat_body(model: &str, request: &GenerateRequest) -> Value {
    let mut messages = Vec::new();
    if let Some(system) = &request.system {
        messages.push(json!({ "role": "system", "content": system }));
    }
    messages.push(json!({ "role": "user", "content": request.prompt }));

    let mut body = json!({
        "model": model,
        "messages": messages,
        "stream": false,
    });

    if let Some(t) = request.config.temperature {
        body["temperature"] = json!(t);
    }
    if let Some(m) = request.config.max_tokens {
        body["max_tokens"] = json!(m);
    }
    // Structured output: ask for JSON mode when a schema is requested. The AI layer still parses and
    // repairs, so this is a best-effort hint, not a hard dependency on server-side schema support.
    if request.format.is_some() {
        body["response_format"] = json!({ "type": "json_object" });
    }

    body
}

#[async_trait::async_trait]
impl LlmProvider for MlxProvider {
    async fn generate(&self, request: GenerateRequest) -> Result<GenerateResponse, LlmError> {
        let model = self.model_for(&request).to_string();
        let body = build_chat_body(&model, &request);
        let url = format!("{}/v1/chat/completions", self.base_url);

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

        let parsed: ChatResponse = resp
            .json()
            .await
            .map_err(|e| LlmError::Decode(e.to_string()))?;

        if let Some(err) = parsed.error {
            return Err(LlmError::Runtime(err.to_string()));
        }

        let text = parsed
            .choices
            .into_iter()
            .next()
            .map(|c| c.message.content)
            .unwrap_or_default();

        Ok(GenerateResponse {
            text,
            model: if parsed.model.is_empty() {
                model
            } else {
                parsed.model
            },
        })
    }

    async fn health(&self) -> Result<(), LlmError> {
        let url = format!("{}/v1/models", self.base_url);
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

    // `embed` intentionally left as the trait default (`Unsupported`): mlx_lm.server does not expose
    // a stable embeddings endpoint. Configure an Ollama embedding model for hybrid search instead.
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::provider::GenerateRequest;
    use serde_json::json;

    #[test]
    fn chat_body_has_system_and_user_messages() {
        let req = GenerateRequest::new("hello").with_system("be terse");
        let body = build_chat_body("qwen3:1.7b", &req);
        assert_eq!(body["model"], "qwen3:1.7b");
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "be terse");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][1]["content"], "hello");
        assert_eq!(body["stream"], false);
        assert!(body.get("response_format").is_none());
    }

    #[test]
    fn chat_body_requests_json_mode_for_structured_output() {
        let req = GenerateRequest::new("extract").with_format(json!({"type": "object"}));
        let body = build_chat_body("qwen3:1.7b", &req);
        assert_eq!(body["response_format"]["type"], "json_object");
    }
}
