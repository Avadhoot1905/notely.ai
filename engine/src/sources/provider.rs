//! The source-provider boundary: API communication, isolated from normalization and indexing.
//!
//! Providers ([`super::slack::SlackProvider`], [`super::teams::TeamsProvider`]) speak their own HTTP
//! dialects here and hand back normalized [`Channel`]/[`Message`] values. All network I/O goes
//! through the [`HttpTransport`] trait, so providers are unit-testable against fixtures with no
//! sockets, and retries/rate-limit handling live in one place ([`fetch_json`]).

use async_trait::async_trait;
use std::time::Duration;

use super::model::{Channel, ImportScope, Message, SourceKind};

/// Errors a source provider can raise. Distinguishes the cases the UI must treat differently:
/// re-auth vs. retry-later vs. give-up.
#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    /// Credentials are missing, invalid, or revoked — the user must reconnect. Never retried.
    #[error("authentication failed: {0}")]
    Auth(String),
    /// The provider throttled us and retries were exhausted.
    #[error("rate limited (retries exhausted): {0}")]
    RateLimited(String),
    /// Network/transport failure.
    #[error("transport error: {0}")]
    Transport(String),
    /// The provider returned a well-formed error.
    #[error("provider error: {0}")]
    Api(String),
    /// A capability the provider does not implement.
    #[error("unsupported: {0}")]
    Unsupported(String),
}

/// A minimal HTTP response, provider-agnostic.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    /// `Retry-After` in seconds, if the server sent one (used for 429 backoff).
    pub retry_after: Option<u64>,
}

/// The single seam through which providers reach the network. Real impl: [`ReqwestTransport`];
/// tests inject a scripted transport.
#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn get(
        &self,
        url: &str,
        headers: &[(String, String)],
    ) -> Result<HttpResponse, SourceError>;
}

/// How hard to retry transient failures. Kept tiny and deterministic; `base_delay` is configurable
/// so tests run instantly.
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: u32,
    pub base_delay: Duration,
    /// Upper bound on any single wait (so a hostile `Retry-After` can't stall the app).
    pub max_delay: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_millis(400),
            max_delay: Duration::from_secs(10),
        }
    }
}

/// GET `url` and parse JSON, transparently handling rate limits (429 + `Retry-After`) and transient
/// 5xx/transport errors with bounded backoff. 401/403 map to [`SourceError::Auth`] and are never
/// retried. This is the one place retry logic lives, so every provider inherits it identically.
pub async fn fetch_json(
    transport: &dyn HttpTransport,
    url: &str,
    headers: &[(String, String)],
    policy: &RetryPolicy,
) -> Result<serde_json::Value, SourceError> {
    let mut attempt = 0u32;
    loop {
        let resp = transport.get(url, headers).await;
        match resp {
            Ok(r) if r.status == 200 => {
                return serde_json::from_str(&r.body)
                    .map_err(|e| SourceError::Api(format!("invalid JSON: {e}")));
            }
            Ok(r) if r.status == 401 || r.status == 403 => {
                return Err(SourceError::Auth(format!("HTTP {}", r.status)));
            }
            Ok(r) if r.status == 429 => {
                if attempt >= policy.max_retries {
                    return Err(SourceError::RateLimited(url.to_string()));
                }
                let wait = r
                    .retry_after
                    .map(Duration::from_secs)
                    .unwrap_or_else(|| backoff(policy, attempt))
                    .min(policy.max_delay);
                sleep(wait).await;
            }
            Ok(r) if r.status >= 500 => {
                if attempt >= policy.max_retries {
                    return Err(SourceError::Transport(format!("HTTP {}", r.status)));
                }
                sleep(backoff(policy, attempt).min(policy.max_delay)).await;
            }
            Ok(r) => {
                // Other 4xx: a real, non-retryable provider error. Surface its body.
                return Err(SourceError::Api(format!(
                    "HTTP {}: {}",
                    r.status,
                    r.body.chars().take(200).collect::<String>()
                )));
            }
            Err(e) => {
                if attempt >= policy.max_retries {
                    return Err(e);
                }
                sleep(backoff(policy, attempt).min(policy.max_delay)).await;
            }
        }
        attempt += 1;
    }
}

fn backoff(policy: &RetryPolicy, attempt: u32) -> Duration {
    // Exponential: base * 2^attempt.
    policy.base_delay.saturating_mul(1u32 << attempt.min(6))
}

async fn sleep(d: Duration) {
    if d.is_zero() {
        return;
    }
    tokio::time::sleep(d).await;
}

/// A connected source: which system, how to authenticate, and how to reach the API. The token lives
/// only in this in-memory value for the life of a request — it is never persisted by the engine.
pub struct SourceProviderConfig {
    pub kind: SourceKind,
    /// Bearer token supplied by the app per-request (from the OS credential store).
    pub token: String,
    /// API base URL override (tests point this at a fixture host).
    pub base_url: String,
    pub retry: RetryPolicy,
}

/// The provider contract: list what can be imported, and fetch normalized messages for a scope.
#[async_trait]
pub trait SourceProvider: Send + Sync {
    fn kind(&self) -> SourceKind;

    /// A recognizable workspace/tenant label for the connected account.
    async fn workspace_label(&self) -> Result<String, SourceError>;

    /// The channels/conversations the user could choose to import.
    async fn list_channels(&self) -> Result<Vec<Channel>, SourceError>;

    /// Fetch normalized messages for one channel within `scope`. Providers paginate internally and
    /// honor `scope.max_messages` so an import is always bounded.
    async fn fetch_messages(
        &self,
        channel: &Channel,
        scope: &ImportScope,
    ) -> Result<Vec<Message>, SourceError>;
}

// ---------------------------------------------------------------------------
// Real transport (reqwest). Thin: it only moves bytes; all policy lives above.
// ---------------------------------------------------------------------------

/// Production [`HttpTransport`] backed by `reqwest`.
pub struct ReqwestTransport {
    client: reqwest::Client,
}

impl ReqwestTransport {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::new(),
        }
    }
}

impl Default for ReqwestTransport {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl HttpTransport for ReqwestTransport {
    async fn get(
        &self,
        url: &str,
        headers: &[(String, String)],
    ) -> Result<HttpResponse, SourceError> {
        let mut req = self.client.get(url);
        for (k, v) in headers {
            req = req.header(k.as_str(), v.as_str());
        }
        let resp = req
            .send()
            .await
            .map_err(|e| SourceError::Transport(e.to_string()))?;
        let status = resp.status().as_u16();
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let body = resp
            .text()
            .await
            .map_err(|e| SourceError::Transport(e.to_string()))?;
        Ok(HttpResponse {
            status,
            body,
            retry_after,
        })
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    //! A scripted transport for provider tests: map a URL substring → a queue of responses.

    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct MockTransport {
        // (url substring, responses in order). First matching, non-empty queue wins.
        routes: Mutex<Vec<(String, VecDeque<HttpResponse>)>>,
        pub calls: Mutex<Vec<String>>,
    }

    impl MockTransport {
        pub fn new() -> Self {
            Self::default()
        }

        /// Queue a 200 JSON response for any URL containing `needle`.
        pub fn on(&self, needle: &str, body: &str) -> &Self {
            self.push(
                needle,
                HttpResponse {
                    status: 200,
                    body: body.to_string(),
                    retry_after: None,
                },
            )
        }

        pub fn push(&self, needle: &str, resp: HttpResponse) -> &Self {
            let mut routes = self.routes.lock().unwrap();
            if let Some(entry) = routes.iter_mut().find(|(n, _)| n == needle) {
                entry.1.push_back(resp);
            } else {
                let mut q = VecDeque::new();
                q.push_back(resp);
                routes.push((needle.to_string(), q));
            }
            self
        }
    }

    #[async_trait]
    impl HttpTransport for MockTransport {
        async fn get(
            &self,
            url: &str,
            _headers: &[(String, String)],
        ) -> Result<HttpResponse, SourceError> {
            self.calls.lock().unwrap().push(url.to_string());
            let mut routes = self.routes.lock().unwrap();
            for (needle, queue) in routes.iter_mut() {
                if url.contains(needle.as_str()) {
                    if let Some(r) = queue.pop_front() {
                        return Ok(r);
                    }
                }
            }
            Err(SourceError::Transport(format!(
                "no mock response for {url}"
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::MockTransport;
    use super::*;

    fn fast_policy() -> RetryPolicy {
        RetryPolicy {
            max_retries: 3,
            base_delay: Duration::ZERO,
            max_delay: Duration::ZERO,
        }
    }

    #[tokio::test]
    async fn retries_then_succeeds_after_rate_limit() {
        let t = MockTransport::new();
        t.push(
            "api",
            HttpResponse {
                status: 429,
                body: String::new(),
                retry_after: Some(0),
            },
        );
        t.on("api", r#"{"ok":true}"#);
        let v = fetch_json(&t, "https://api/x", &[], &fast_policy())
            .await
            .unwrap();
        assert_eq!(v["ok"], serde_json::json!(true));
        assert_eq!(t.calls.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn auth_errors_are_not_retried() {
        let t = MockTransport::new();
        t.push(
            "api",
            HttpResponse {
                status: 401,
                body: String::new(),
                retry_after: None,
            },
        );
        let err = fetch_json(&t, "https://api/x", &[], &fast_policy())
            .await
            .unwrap_err();
        assert!(matches!(err, SourceError::Auth(_)));
        assert_eq!(
            t.calls.lock().unwrap().len(),
            1,
            "auth failure must not retry"
        );
    }
}
