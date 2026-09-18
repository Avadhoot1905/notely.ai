//! Microsoft Teams as a knowledge source (Microsoft Graph).
//!
//! Same shape as Slack ([`super::slack`]): read-only import of channels the user chose, normalized
//! into provenance-bearing [`Message`]s. Teams nests channels under teams, so a channel id here is
//! `"{team_id}/{channel_id}"`. Graph paginates with absolute `@odata.nextLink` URLs and returns
//! message bodies as HTML, both handled here. Reuses the shared retry/rate-limit and provider
//! abstractions rather than duplicating them.

use async_trait::async_trait;

use super::model::{Channel, ImportScope, Message, SourceKind};
use super::provider::{
    fetch_json, HttpTransport, RetryPolicy, SourceError, SourceProvider, SourceProviderConfig,
};

/// Default Microsoft Graph base. Overridable (tests point it at a fixture host).
pub const GRAPH_API_BASE: &str = "https://graph.microsoft.com/v1.0";

pub struct TeamsProvider {
    transport: std::sync::Arc<dyn HttpTransport>,
    token: String,
    base_url: String,
    retry: RetryPolicy,
}

impl TeamsProvider {
    pub fn new(transport: std::sync::Arc<dyn HttpTransport>, cfg: SourceProviderConfig) -> Self {
        Self {
            transport,
            token: cfg.token,
            base_url: if cfg.base_url.is_empty() {
                GRAPH_API_BASE.to_string()
            } else {
                cfg.base_url
            },
            retry: cfg.retry,
        }
    }

    fn headers(&self) -> Vec<(String, String)> {
        vec![("Authorization".into(), format!("Bearer {}", self.token))]
    }

    /// Call a Graph endpoint by path (joined to the base).
    async fn call(&self, path: &str) -> Result<serde_json::Value, SourceError> {
        let url = format!("{}/{}", self.base_url, path);
        self.call_url(&url).await
    }

    /// Call an absolute URL (used for `@odata.nextLink`).
    async fn call_url(&self, url: &str) -> Result<serde_json::Value, SourceError> {
        let v = fetch_json(self.transport.as_ref(), url, &self.headers(), &self.retry).await?;
        if let Some(err) = v.get("error") {
            let msg = err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown");
            return Err(SourceError::Api(msg.to_string()));
        }
        Ok(v)
    }
}

fn next_link(v: &serde_json::Value) -> Option<String> {
    v.get("@odata.nextLink")
        .and_then(|l| l.as_str())
        .map(|s| s.to_string())
}

/// Strip HTML to readable text (Graph message bodies are usually `contentType: html`). Minimal by
/// design — enough to make imported content searchable and readable, not a full HTML renderer.
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for ch in html.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_message(v: &serde_json::Value, thread_id: Option<String>) -> Option<Message> {
    let id = v.get("id").and_then(|i| i.as_str())?.to_string();
    let content = v
        .get("body")
        .and_then(|b| b.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("");
    let content_type = v
        .get("body")
        .and_then(|b| b.get("contentType"))
        .and_then(|c| c.as_str())
        .unwrap_or("text");
    let text = if content_type.eq_ignore_ascii_case("html") {
        html_to_text(content)
    } else {
        content.trim().to_string()
    };
    let author = v
        .get("from")
        .and_then(|f| f.get("user"))
        .and_then(|u| u.get("displayName"))
        .and_then(|n| n.as_str())
        .map(|s| s.to_string());
    Some(Message {
        id,
        thread_id,
        author,
        text,
        timestamp: v
            .get("createdDateTime")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string()),
        permalink: v
            .get("webUrl")
            .and_then(|u| u.as_str())
            .map(|s| s.to_string()),
    })
}

#[async_trait]
impl SourceProvider for TeamsProvider {
    fn kind(&self) -> SourceKind {
        SourceKind::Teams
    }

    async fn workspace_label(&self) -> Result<String, SourceError> {
        let v = self.call("organization").await?;
        Ok(v.get("value")
            .and_then(|a| a.as_array())
            .and_then(|a| a.first())
            .and_then(|o| o.get("displayName"))
            .and_then(|n| n.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "Microsoft Teams".to_string()))
    }

    async fn list_channels(&self) -> Result<Vec<Channel>, SourceError> {
        let teams = self.call("me/joinedTeams").await?;
        let mut out = Vec::new();
        if let Some(arr) = teams.get("value").and_then(|a| a.as_array()) {
            for team in arr.iter().take(50) {
                let team_id = team.get("id").and_then(|i| i.as_str()).unwrap_or("");
                let team_name = team
                    .get("displayName")
                    .and_then(|n| n.as_str())
                    .unwrap_or("Team");
                if team_id.is_empty() {
                    continue;
                }
                let chans = self
                    .call(&format!("teams/{team_id}/channels"))
                    .await
                    .unwrap_or_else(|_| serde_json::json!({"value": []}));
                if let Some(cs) = chans.get("value").and_then(|a| a.as_array()) {
                    for c in cs {
                        let cid = c.get("id").and_then(|i| i.as_str()).unwrap_or("");
                        if cid.is_empty() {
                            continue;
                        }
                        out.push(Channel {
                            id: format!("{team_id}/{cid}"),
                            name: format!(
                                "{team_name} / {}",
                                c.get("displayName")
                                    .and_then(|n| n.as_str())
                                    .unwrap_or("channel")
                            ),
                            purpose: c
                                .get("description")
                                .and_then(|d| d.as_str())
                                .filter(|s| !s.is_empty())
                                .map(|s| s.to_string()),
                            member_count: None,
                        });
                    }
                }
            }
        }
        Ok(out)
    }

    async fn fetch_messages(
        &self,
        channel: &Channel,
        scope: &ImportScope,
    ) -> Result<Vec<Message>, SourceError> {
        let (team_id, channel_id) = channel
            .id
            .split_once('/')
            .ok_or_else(|| SourceError::Api(format!("bad Teams channel id: {}", channel.id)))?;
        let cap = scope.max_messages.unwrap_or(1_000);
        let since = scope.since.clone();

        // Root messages, following nextLink until the cap.
        let mut roots: Vec<serde_json::Value> = Vec::new();
        let mut url = Some(format!(
            "{}/teams/{team_id}/channels/{channel_id}/messages?$top=50",
            self.base_url
        ));
        while let Some(u) = url.take() {
            let v = self.call_url(&u).await?;
            if let Some(arr) = v.get("value").and_then(|a| a.as_array()) {
                for m in arr {
                    roots.push(m.clone());
                    if roots.len() >= cap {
                        break;
                    }
                }
            }
            if roots.len() >= cap {
                break;
            }
            url = next_link(&v);
        }

        let mut out: Vec<Message> = Vec::new();
        for m in &roots {
            if let Some(msg) = parse_message(m, None) {
                if within_since(&msg, since.as_deref()) && !msg.text.is_empty() {
                    out.push(msg);
                }
            }
        }
        // Best-effort: pull one page of replies for each root so threaded discussion is preserved.
        for m in roots.iter().take(cap) {
            if out.len() >= cap {
                break;
            }
            let root_id = m.get("id").and_then(|i| i.as_str()).unwrap_or("");
            if root_id.is_empty() {
                continue;
            }
            let replies = self
                .call(&format!(
                    "teams/{team_id}/channels/{channel_id}/messages/{root_id}/replies?$top=50"
                ))
                .await;
            if let Ok(v) = replies {
                if let Some(arr) = v.get("value").and_then(|a| a.as_array()) {
                    for r in arr {
                        if let Some(msg) = parse_message(r, Some(root_id.to_string())) {
                            if within_since(&msg, since.as_deref()) && !msg.text.is_empty() {
                                out.push(msg);
                            }
                        }
                    }
                }
            }
        }
        out.sort_by(|a, b| a.timestamp.cmp(&b.timestamp).then(a.id.cmp(&b.id)));
        out.truncate(cap);
        Ok(out)
    }
}

/// Client-side `since` filter (Graph's message filtering is limited).
fn within_since(msg: &Message, since: Option<&str>) -> bool {
    match (since, msg.timestamp.as_deref()) {
        (Some(s), Some(ts)) => ts >= s, // RFC3339 sorts lexicographically for same offset
        (Some(_), None) => true,
        (None, _) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::super::provider::test_support::MockTransport;
    use super::*;
    use std::sync::Arc;

    fn provider(t: Arc<MockTransport>) -> TeamsProvider {
        TeamsProvider::new(
            t,
            SourceProviderConfig {
                kind: SourceKind::Teams,
                token: "graph-test".into(),
                base_url: "https://mockgraph".into(),
                retry: RetryPolicy {
                    max_retries: 1,
                    base_delay: std::time::Duration::ZERO,
                    max_delay: std::time::Duration::ZERO,
                },
            },
        )
    }

    #[tokio::test]
    async fn lists_channels_and_normalizes_html_messages() {
        let t = Arc::new(MockTransport::new());
        t.on("organization", r#"{"value":[{"displayName":"Contoso"}]}"#);
        t.on(
            "me/joinedTeams",
            r#"{"value":[{"id":"T1","displayName":"Engineering"}]}"#,
        );
        t.on(
            "teams/T1/channels",
            r#"{"value":[{"id":"19:abc","displayName":"Architecture","description":"design"}]}"#,
        );
        t.on(
            "channels/19:abc/messages?",
            r#"{"value":[{"id":"m1","from":{"user":{"displayName":"Grace Hopper"}},"body":{"contentType":"html","content":"<p>We chose <b>TLS proxy</b>.</p>"},"createdDateTime":"2021-01-01T00:00:00Z","webUrl":"https://teams.microsoft.com/l/message/m1"}]}"#,
        );
        t.on("messages/m1/replies", r#"{"value":[{"id":"r1","from":{"user":{"displayName":"Alan"}},"body":{"contentType":"text","content":"Agreed on attribution."},"createdDateTime":"2021-01-01T00:05:00Z"}]}"#);

        let p = provider(t);
        assert_eq!(p.workspace_label().await.unwrap(), "Contoso");
        let chans = p.list_channels().await.unwrap();
        assert_eq!(chans.len(), 1);
        assert_eq!(chans[0].id, "T1/19:abc");
        assert_eq!(chans[0].name, "Engineering / Architecture");

        let msgs = p
            .fetch_messages(
                &chans[0],
                &ImportScope {
                    channel_ids: vec![chans[0].id.clone()],
                    since: None,
                    max_messages: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].text, "We chose TLS proxy.");
        assert_eq!(msgs[0].author.as_deref(), Some("Grace Hopper"));
        // Reply is threaded under the root.
        let reply = msgs.iter().find(|m| m.id == "r1").unwrap();
        assert_eq!(reply.thread_id.as_deref(), Some("m1"));
    }

    #[test]
    fn html_to_text_strips_tags_and_entities() {
        assert_eq!(
            html_to_text("<p>Hello&nbsp;<b>world</b> &amp; more</p>"),
            "Hello world & more"
        );
    }
}
