//! External knowledge sources — Slack, Teams, and the ingestion that folds them into the vault.
//!
//! The layering is deliberate and matches the rest of the engine:
//!   - [`provider`] — API communication (isolated behind [`provider::HttpTransport`]).
//!   - [`slack`] / [`teams`] — provider-specific normalization into [`model::Message`].
//!   - [`markdown`] — turning normalized messages into provenance-bearing vault notes.
//!   - [`registry`] — durable, **non-secret** bookkeeping (what's connected/imported, dedup ledger).
//!   - [`Ingestor`] — orchestration: fetch → normalize → write → index (via the caller) → record.
//!
//! Slack/Teams structures never leak past this module: everything the rest of Notely sees is either
//! a normalized [`model`] type or an ordinary Markdown note in the vault. Tokens are passed per
//! request and never persisted.

pub mod markdown;
pub mod model;
pub mod provider;
pub mod registry;
pub mod slack;
pub mod teams;

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use model::{Channel, ConnectedSource, ImportScope, ImportSummary, SourceKind};
use provider::{HttpTransport, RetryPolicy, SourceError, SourceProvider, SourceProviderConfig};
use registry::SourceRegistry;
use slack::SlackProvider;
use teams::TeamsProvider;

/// Top-level folder (relative to the vault) that holds all imported knowledge. Non-dotted so the
/// index picks it up; grouped so the user can see and delete imported content at a glance.
pub const IMPORT_ROOT: &str = "Imported";

/// The vault-relative folder for a source kind (e.g. `Imported/Slack`).
pub fn sources_folder(kind: SourceKind) -> String {
    let sub = match kind {
        SourceKind::Slack => "Slack",
        SourceKind::Teams => "Teams",
    };
    format!("{IMPORT_ROOT}/{sub}")
}

/// Classify an indexed note path by the source it came from — used to tag Knowledge Space concepts
/// with provenance (`"slack"`, `"teams"`, or `"markdown"` for ordinary notes). Path-separator and
/// case tolerant.
pub fn source_kind_for_path(path: &str) -> String {
    let comps: Vec<String> = Path::new(path)
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().to_ascii_lowercase()),
            _ => None,
        })
        .collect();
    for w in comps.windows(2) {
        if w[0] == IMPORT_ROOT.to_ascii_lowercase() {
            match w[1].as_str() {
                "slack" => return "slack".to_string(),
                "teams" => return "teams".to_string(),
                _ => {}
            }
        }
    }
    "markdown".to_string()
}

/// Orchestrates imports across providers. Owns the registry and the HTTP transport; providers are
/// built per request from a caller-supplied (in-memory) token.
pub struct Ingestor {
    registry: SourceRegistry,
    transport: Arc<dyn HttpTransport>,
}

impl Ingestor {
    pub fn new(registry: SourceRegistry, transport: Arc<dyn HttpTransport>) -> Self {
        Self {
            registry,
            transport,
        }
    }

    fn provider(
        &self,
        kind: SourceKind,
        token: String,
        base_url: String,
    ) -> Box<dyn SourceProvider> {
        let cfg = SourceProviderConfig {
            kind,
            token,
            base_url,
            retry: RetryPolicy::default(),
        };
        match kind {
            SourceKind::Slack => Box::new(SlackProvider::new(self.transport.clone(), cfg)),
            SourceKind::Teams => Box::new(TeamsProvider::new(self.transport.clone(), cfg)),
        }
    }

    /// List importable channels for a source (used by the Connect/Import UI). Also returns the
    /// resolved workspace label so the UI can confirm the account.
    pub async fn list_channels(
        &self,
        kind: SourceKind,
        token: String,
        base_url: String,
    ) -> Result<(String, Vec<Channel>), SourceError> {
        let provider = self.provider(kind, token, base_url);
        let workspace = provider.workspace_label().await?;
        let channels = provider.list_channels().await?;
        Ok((workspace, channels))
    }

    /// Import the chosen channels into `vault_path`, returning a summary. Idempotent (dedup by
    /// message id) and partial-failure tolerant (a channel that fails is a warning, not an abort).
    ///
    /// Does **not** re-index: the caller syncs the vault afterward so imported notes become
    /// searchable (keeps this module free of any search dependency).
    pub async fn import(
        &self,
        vault_path: &Path,
        kind: SourceKind,
        token: String,
        base_url: String,
        scope: ImportScope,
        now_rfc3339: &str,
    ) -> Result<ImportSummary, SourceError> {
        let provider = self.provider(kind, token, base_url);
        let workspace = provider.workspace_label().await?;
        let folder = sources_folder(kind);
        self.registry
            .upsert_source(kind, &workspace, &folder)
            .await
            .map_err(|e| SourceError::Api(e.to_string()))?;

        // Resolve chosen ids → channels (names, etc.).
        let all = provider.list_channels().await?;
        let chosen: Vec<Channel> = all
            .into_iter()
            .filter(|c| scope.channel_ids.iter().any(|id| id == &c.id))
            .collect();

        let dir = vault_path.join(&folder);
        let mut summary = ImportSummary::default();

        for channel in &chosen {
            match self
                .import_channel(
                    provider.as_ref(),
                    &dir,
                    kind,
                    &workspace,
                    channel,
                    &scope,
                    now_rfc3339,
                )
                .await
            {
                Ok((written, skipped, wrote_doc)) => {
                    summary.channels_imported += 1;
                    summary.messages_imported += written;
                    summary.messages_skipped += skipped;
                    if wrote_doc {
                        summary.documents_written += 1;
                    }
                }
                Err(e) => summary.warnings.push(format!("{}: {e}", channel.name)),
            }
        }
        Ok(summary)
    }

    /// Import one channel through an already-built provider. Returns
    /// `(new_messages, skipped, wrote_document)`. Idempotent: only messages unseen in the registry
    /// are written and recorded.
    async fn import_channel(
        &self,
        provider: &dyn SourceProvider,
        dir: &Path,
        kind: SourceKind,
        workspace: &str,
        channel: &Channel,
        scope: &ImportScope,
        now: &str,
    ) -> Result<(usize, usize, bool), SourceError> {
        let messages = provider.fetch_messages(channel, scope).await?;
        let ids: Vec<String> = messages.iter().map(|m| m.id.clone()).collect();
        let total = ids.len();
        let unseen = self
            .registry
            .unseen(kind, &channel.id, ids)
            .await
            .map_err(|e| SourceError::Api(e.to_string()))?;
        if unseen.is_empty() {
            return Ok((0, total, false));
        }
        let unseen_set: std::collections::HashSet<&String> = unseen.iter().collect();
        let mut blocks = String::new();
        let mut new_ids = Vec::new();
        for m in &messages {
            if unseen_set.contains(&m.id) {
                blocks.push_str(&markdown::message_block(kind, m));
                new_ids.push(m.id.clone());
            }
        }
        let (channel_owned, dir_owned, workspace_owned, now_owned) = (
            channel.clone(),
            dir.to_path_buf(),
            workspace.to_string(),
            now.to_string(),
        );
        let (_, is_new) = tokio::task::spawn_blocking(move || {
            write_channel_note(
                &dir_owned,
                kind,
                &workspace_owned,
                &channel_owned,
                &blocks,
                &now_owned,
            )
        })
        .await
        .map_err(|e| SourceError::Api(e.to_string()))?
        .map_err(|e| SourceError::Api(format!("write failed: {e}")))?;

        let new_count = new_ids.len();
        self.registry
            .record_import(kind, &channel.id, &channel.name, new_ids, now)
            .await
            .map_err(|e| SourceError::Api(e.to_string()))?;
        Ok((new_count, total - new_count, is_new))
    }

    /// Connected sources + their import summaries.
    pub async fn list_sources(&self) -> Result<Vec<ConnectedSource>, SourceError> {
        self.registry
            .list_sources()
            .await
            .map_err(|e| SourceError::Api(e.to_string()))
    }

    /// Disconnect a source: forget its bookkeeping and, when `remove_imported`, delete its Markdown
    /// folder from the vault. The caller re-syncs the index afterward to prune the removed notes.
    pub async fn disconnect(
        &self,
        vault_path: &Path,
        kind: SourceKind,
        remove_imported: bool,
    ) -> Result<(), SourceError> {
        let folder = self
            .registry
            .remove_source(kind)
            .await
            .map_err(|e| SourceError::Api(e.to_string()))?;
        if remove_imported {
            if let Some(folder) = folder {
                let dir = vault_path.join(folder);
                let _ = tokio::task::spawn_blocking(move || std::fs::remove_dir_all(dir)).await;
            }
        }
        Ok(())
    }

    pub fn registry(&self) -> &SourceRegistry {
        &self.registry
    }
}

/// Append a rendered message block to a channel note, writing the frontmatter header the first time.
/// Returns whether the file was newly created.
fn write_channel_note(
    dir: &Path,
    kind: SourceKind,
    workspace: &str,
    channel: &Channel,
    blocks: &str,
    now: &str,
) -> std::io::Result<(PathBuf, bool)> {
    std::fs::create_dir_all(dir)?;
    let path = dir.join(format!("{}.md", markdown::safe_stem(&channel.name)));
    let is_new = !path.exists();
    let mut content = String::new();
    if is_new {
        content.push_str(&markdown::channel_header(
            kind,
            workspace,
            &channel.name,
            &channel.id,
            now,
        ));
    }
    content.push_str(blocks);
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    f.write_all(content.as_bytes())?;
    Ok((path, is_new))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_paths_by_source() {
        assert_eq!(
            source_kind_for_path("/vault/Imported/Slack/architecture.md"),
            "slack"
        );
        assert_eq!(
            source_kind_for_path("/vault/Imported/Teams/eng.md"),
            "teams"
        );
        assert_eq!(
            source_kind_for_path("/vault/notes/decisions.md"),
            "markdown"
        );
        // Case/separator tolerant.
        assert_eq!(
            source_kind_for_path("C:/Vault/imported/slack/x.md"),
            "slack"
        );
    }

    #[test]
    fn sources_folder_is_grouped_and_non_dotted() {
        assert_eq!(sources_folder(SourceKind::Slack), "Imported/Slack");
        assert_eq!(sources_folder(SourceKind::Teams), "Imported/Teams");
    }

    use super::provider::test_support::MockTransport;
    use crate::search::SearchIndex;

    fn temp_vault() -> PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let base = std::env::temp_dir().join(format!(
            "notely-import-test-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    /// Queue one full round of Slack fixtures (used per import; the mock consumes each response).
    fn queue_slack_round(t: &MockTransport) {
        t.on(
            "auth.test",
            r#"{"ok":true,"team":"Acme","url":"https://acme.slack.com/"}"#,
        );
        t.on(
            "users.list",
            r#"{"ok":true,"members":[{"id":"U1","profile":{"real_name":"Ada"}}]}"#,
        );
        t.on(
            "conversations.list",
            r#"{"ok":true,"channels":[{"id":"C1","name":"architecture"}]}"#,
        );
        t.on(
            "conversations.history",
            r#"{"ok":true,"messages":[{"ts":"1609459200.000200","user":"U1","text":"We chose a TLS proxy for MITM interception."},{"ts":"1609459300.000000","user":"U1","text":"Netwatch handles process attribution."}]}"#,
        );
    }

    #[tokio::test]
    async fn imports_slack_into_vault_idempotently_and_becomes_searchable() {
        let t = Arc::new(MockTransport::new());
        queue_slack_round(&t);
        queue_slack_round(&t); // second round for the idempotency re-import

        let registry = SourceRegistry::open_in_memory().unwrap();
        let ingestor = Ingestor::new(registry, t.clone());
        let vault = temp_vault();
        let scope = ImportScope {
            channel_ids: vec!["C1".into()],
            since: None,
            max_messages: None,
        };

        let s1 = ingestor
            .import(
                &vault,
                SourceKind::Slack,
                "xoxb-test".into(),
                "https://mock/api".into(),
                scope.clone(),
                "2026-01-01T00:00:00Z",
            )
            .await
            .unwrap();
        assert_eq!(s1.messages_imported, 2);
        assert_eq!(s1.documents_written, 1);

        // The imported note is real Markdown with provenance frontmatter.
        let note = vault.join("Imported/Slack/architecture.md");
        let body = std::fs::read_to_string(&note).unwrap();
        assert!(body.contains("notely_source: slack"));
        assert!(body.contains("TLS proxy"));

        // Re-import is idempotent: nothing new, nothing duplicated.
        let s2 = ingestor
            .import(
                &vault,
                SourceKind::Slack,
                "xoxb-test".into(),
                "https://mock/api".into(),
                scope,
                "2026-01-02T00:00:00Z",
            )
            .await
            .unwrap();
        assert_eq!(s2.messages_imported, 0);
        assert_eq!(s2.messages_skipped, 2);

        // The imported knowledge is searchable through the *existing* index, with a citable path.
        let index = SearchIndex::open_in_memory().unwrap();
        index.sync_vault(vault.clone()).await.unwrap();
        let hits = index.search("attribution", 5).await.unwrap();
        assert!(hits.iter().any(|h| h.path.contains("Imported/Slack")));

        // And the Knowledge Space tags those concepts as Slack-sourced.
        let chunks = index.all_chunks().await.unwrap();
        assert!(chunks
            .iter()
            .any(|(p, _, _)| super::source_kind_for_path(p) == "slack"));

        let _ = std::fs::remove_dir_all(&vault);
    }
}
