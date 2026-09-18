//! Slack as a knowledge source (Slack Web API).
//!
//! Not a Slack client — a read-only importer. It lists conversations, pulls a *bounded* page of
//! history for the channels the user explicitly chose, resolves author names, and normalizes each
//! message into a provenance-bearing [`Message`]. Slack's `ok:false` envelope, cursor pagination,
//! and 429 throttling are all handled here (the last via [`fetch_json`]).

use async_trait::async_trait;
use std::collections::HashMap;

use super::model::{Channel, ImportScope, Message, SourceKind};
use super::provider::{
    fetch_json, HttpTransport, RetryPolicy, SourceError, SourceProvider, SourceProviderConfig,
};

/// Default Slack API base. Overridable (tests point it at a fixture host).
pub const SLACK_API_BASE: &str = "https://slack.com/api";

pub struct SlackProvider {
    transport: std::sync::Arc<dyn HttpTransport>,
    token: String,
    base_url: String,
    retry: RetryPolicy,
    /// Lazily-loaded `user_id -> display name` map (best-effort; missing names fall back to the id).
    users: tokio::sync::Mutex<Option<HashMap<String, String>>>,
    /// Workspace archive URL base (from `auth.test`), used to build message permalinks.
    team_url: tokio::sync::Mutex<Option<String>>,
}

impl SlackProvider {
    pub fn new(transport: std::sync::Arc<dyn HttpTransport>, cfg: SourceProviderConfig) -> Self {
        Self {
            transport,
            token: cfg.token,
            base_url: if cfg.base_url.is_empty() {
                SLACK_API_BASE.to_string()
            } else {
                cfg.base_url
            },
            retry: cfg.retry,
            users: tokio::sync::Mutex::new(None),
            team_url: tokio::sync::Mutex::new(None),
        }
    }

    fn headers(&self) -> Vec<(String, String)> {
        vec![("Authorization".into(), format!("Bearer {}", self.token))]
    }

    async fn call(&self, path_and_query: &str) -> Result<serde_json::Value, SourceError> {
        let url = format!("{}/{}", self.base_url, path_and_query);
        let v = fetch_json(self.transport.as_ref(), &url, &self.headers(), &self.retry).await?;
        // Slack signals logical failure with `ok:false` even on HTTP 200.
        if v.get("ok").and_then(|o| o.as_bool()) == Some(false) {
            let err = v.get("error").and_then(|e| e.as_str()).unwrap_or("unknown");
            return match err {
                "invalid_auth" | "not_authed" | "token_revoked" | "account_inactive" => {
                    Err(SourceError::Auth(err.to_string()))
                }
                "ratelimited" => Err(SourceError::RateLimited(err.to_string())),
                other => Err(SourceError::Api(other.to_string())),
            };
        }
        Ok(v)
    }

    /// Populate the user-name cache (once) from `users.list`. Best-effort: on failure the cache is
    /// left empty and authors show as raw ids rather than aborting the import.
    async fn ensure_users(&self) {
        {
            let guard = self.users.lock().await;
            if guard.is_some() {
                return;
            }
        }
        let mut map = HashMap::new();
        let mut cursor: Option<String> = None;
        for _ in 0..20 {
            let q = match &cursor {
                Some(c) => format!("users.list?limit=200&cursor={c}"),
                None => "users.list?limit=200".to_string(),
            };
            let Ok(v) = self.call(&q).await else { break };
            if let Some(members) = v.get("members").and_then(|m| m.as_array()) {
                for m in members {
                    let id = m.get("id").and_then(|i| i.as_str()).unwrap_or("");
                    let name = m
                        .get("profile")
                        .and_then(|p| p.get("real_name"))
                        .and_then(|n| n.as_str())
                        .filter(|s| !s.is_empty())
                        .or_else(|| m.get("name").and_then(|n| n.as_str()))
                        .unwrap_or(id);
                    if !id.is_empty() {
                        map.insert(id.to_string(), name.to_string());
                    }
                }
            }
            cursor = next_cursor(&v);
            if cursor.is_none() {
                break;
            }
        }
        *self.users.lock().await = Some(map);
    }

    async fn author_name(&self, user_id: &str) -> Option<String> {
        if user_id.is_empty() {
            return None;
        }
        self.ensure_users().await;
        let guard = self.users.lock().await;
        Some(
            guard
                .as_ref()
                .and_then(|m| m.get(user_id).cloned())
                .unwrap_or_else(|| user_id.to_string()),
        )
    }

    async fn permalink(&self, channel_id: &str, ts: &str) -> Option<String> {
        let guard = self.team_url.lock().await;
        let base = guard.as_ref()?;
        // https://team.slack.com/archives/CHANNEL/pTIMESTAMP
        Some(format!(
            "{}archives/{}/p{}",
            base,
            channel_id,
            ts.replace('.', "")
        ))
    }
}

/// Pull the `response_metadata.next_cursor` (empty string means "no more").
fn next_cursor(v: &serde_json::Value) -> Option<String> {
    v.get("response_metadata")
        .and_then(|m| m.get("next_cursor"))
        .and_then(|c| c.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// Slack `ts` ("1609459200.000200") → RFC3339, best-effort.
fn ts_to_rfc3339(ts: &str) -> Option<String> {
    let secs: i64 = ts.split('.').next()?.parse().ok()?;
    let frac = ts.split('.').nth(1).and_then(|f| f.parse::<u32>().ok());
    let nanos = frac.map(|micro| micro.saturating_mul(1000)).unwrap_or(0);
    chrono::DateTime::from_timestamp(secs, nanos).map(|dt| dt.to_rfc3339())
}

#[async_trait]
impl SourceProvider for SlackProvider {
    fn kind(&self) -> SourceKind {
        SourceKind::Slack
    }

    async fn workspace_label(&self) -> Result<String, SourceError> {
        let v = self.call("auth.test").await?;
        if let Some(url) = v.get("url").and_then(|u| u.as_str()) {
            *self.team_url.lock().await = Some(url.to_string());
        }
        Ok(v.get("team")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                v.get("url").and_then(|u| u.as_str()).map(|s| {
                    s.trim_start_matches("https://")
                        .trim_end_matches('/')
                        .to_string()
                })
            })
            .unwrap_or_else(|| "Slack workspace".to_string()))
    }

    async fn list_channels(&self) -> Result<Vec<Channel>, SourceError> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..20 {
            let q = match &cursor {
                Some(c) => format!(
                    "conversations.list?limit=200&exclude_archived=true&types=public_channel,private_channel&cursor={c}"
                ),
                None => "conversations.list?limit=200&exclude_archived=true&types=public_channel,private_channel".to_string(),
            };
            let v = self.call(&q).await?;
            if let Some(chans) = v.get("channels").and_then(|c| c.as_array()) {
                for c in chans {
                    let id = c
                        .get("id")
                        .and_then(|i| i.as_str())
                        .unwrap_or("")
                        .to_string();
                    if id.is_empty() {
                        continue;
                    }
                    out.push(Channel {
                        id,
                        name: c
                            .get("name")
                            .and_then(|n| n.as_str())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| "channel".into()),
                        purpose: c
                            .get("purpose")
                            .and_then(|p| p.get("value"))
                            .and_then(|v| v.as_str())
                            .filter(|s| !s.is_empty())
                            .map(|s| s.to_string()),
                        member_count: c.get("num_members").and_then(|n| n.as_u64()),
                    });
                }
            }
            cursor = next_cursor(&v);
            if cursor.is_none() {
                break;
            }
        }
        Ok(out)
    }

    async fn fetch_messages(
        &self,
        channel: &Channel,
        scope: &ImportScope,
    ) -> Result<Vec<Message>, SourceError> {
        let cap = scope.max_messages.unwrap_or(1_000);
        let oldest = scope
            .since
            .as_deref()
            .and_then(rfc3339_to_epoch)
            .map(|s| format!("&oldest={s}"))
            .unwrap_or_default();
        let mut collected: Vec<serde_json::Value> = Vec::new();
        let mut cursor: Option<String> = None;
        // Bounded page loop; each page is <=200 and we stop at `cap`.
        for _ in 0..50 {
            let q = match &cursor {
                Some(c) => format!(
                    "conversations.history?channel={}&limit=200{oldest}&cursor={c}",
                    channel.id
                ),
                None => format!(
                    "conversations.history?channel={}&limit=200{oldest}",
                    channel.id
                ),
            };
            let v = self.call(&q).await?;
            if let Some(msgs) = v.get("messages").and_then(|m| m.as_array()) {
                for m in msgs {
                    // Skip join/leave and other subtype noise; keep only real messages.
                    if m.get("subtype").is_some() {
                        continue;
                    }
                    collected.push(m.clone());
                    if collected.len() >= cap {
                        break;
                    }
                }
            }
            if collected.len() >= cap {
                break;
            }
            cursor = next_cursor(&v);
            if cursor.is_none() {
                break;
            }
        }

        let mut out = Vec::with_capacity(collected.len());
        for m in collected {
            let ts = m
                .get("ts")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            let user = m.get("user").and_then(|u| u.as_str()).unwrap_or("");
            let thread_ts = m.get("thread_ts").and_then(|t| t.as_str());
            let thread_id = thread_ts.filter(|t| *t != ts).map(|t| t.to_string());
            out.push(Message {
                id: ts.clone(),
                thread_id,
                author: self.author_name(user).await,
                text: m
                    .get("text")
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_string(),
                timestamp: ts_to_rfc3339(&ts),
                permalink: self.permalink(&channel.id, &ts).await,
            });
        }
        // Chronological order (Slack returns newest-first).
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(out)
    }
}

/// RFC3339 → Slack epoch-seconds string for the `oldest` bound.
fn rfc3339_to_epoch(s: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp().to_string())
}

#[cfg(test)]
mod tests {
    use super::super::provider::test_support::MockTransport;
    use super::*;
    use std::sync::Arc;

    fn provider(t: Arc<MockTransport>) -> SlackProvider {
        SlackProvider::new(
            t,
            SourceProviderConfig {
                kind: SourceKind::Slack,
                token: "xoxb-test".into(),
                base_url: "https://mock/api".into(),
                retry: RetryPolicy {
                    max_retries: 1,
                    base_delay: std::time::Duration::ZERO,
                    max_delay: std::time::Duration::ZERO,
                },
            },
        )
    }

    #[tokio::test]
    async fn lists_channels_and_normalizes_messages_with_provenance() {
        let t = Arc::new(MockTransport::new());
        t.on(
            "auth.test",
            r#"{"ok":true,"team":"Acme","url":"https://acme.slack.com/"}"#,
        );
        t.on(
            "users.list",
            r#"{"ok":true,"members":[{"id":"U1","profile":{"real_name":"Ada Lovelace"}}]}"#,
        );
        t.on(
            "conversations.list",
            r#"{"ok":true,"channels":[{"id":"C1","name":"architecture","purpose":{"value":"design chat"},"num_members":12}]}"#,
        );
        t.on(
            "conversations.history",
            r#"{"ok":true,"messages":[{"ts":"1609459200.000200","user":"U1","text":"We chose TLS proxy for MITM.","thread_ts":"1609459200.000200"},{"ts":"1609459300.000000","user":"U1","text":"Follow-up on attribution.","thread_ts":"1609459200.000200"}]}"#,
        );

        let p = provider(t);
        assert_eq!(p.workspace_label().await.unwrap(), "Acme");

        let chans = p.list_channels().await.unwrap();
        assert_eq!(chans.len(), 1);
        assert_eq!(chans[0].name, "architecture");

        let msgs = p
            .fetch_messages(
                &chans[0],
                &ImportScope {
                    channel_ids: vec!["C1".into()],
                    since: None,
                    max_messages: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].author.as_deref(), Some("Ada Lovelace"));
        assert!(msgs[0].timestamp.is_some());
        assert!(msgs[0]
            .permalink
            .as_deref()
            .unwrap()
            .contains("acme.slack.com/archives/C1/p1609459200000200"));
        // The second message is a threaded reply.
        assert_eq!(msgs[1].thread_id.as_deref(), Some("1609459200.000200"));
    }

    #[tokio::test]
    async fn revoked_token_surfaces_as_auth_error() {
        let t = Arc::new(MockTransport::new());
        t.on("auth.test", r#"{"ok":false,"error":"token_revoked"}"#);
        let p = provider(t);
        assert!(matches!(
            p.workspace_label().await.unwrap_err(),
            SourceError::Auth(_)
        ));
    }
}
