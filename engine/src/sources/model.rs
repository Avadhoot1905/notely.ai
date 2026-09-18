//! The normalized, provider-agnostic shape of imported external knowledge.
//!
//! Slack and Teams (and anything added later) are *knowledge sources*, not embedded clients. Their
//! wire formats never leak past the provider boundary: everything is normalized into these types,
//! which carry enough provenance for a search result to name exactly where a claim came from.

use serde::{Deserialize, Serialize};

/// Which external system a piece of knowledge came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    Slack,
    Teams,
}

impl SourceKind {
    /// Lowercase tag used in paths, frontmatter, and the Knowledge Space provenance.
    pub fn tag(&self) -> &'static str {
        match self {
            SourceKind::Slack => "slack",
            SourceKind::Teams => "teams",
        }
    }

    /// Human-facing label.
    pub fn label(&self) -> &'static str {
        match self {
            SourceKind::Slack => "Slack",
            SourceKind::Teams => "Microsoft Teams",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "slack" => Some(SourceKind::Slack),
            "teams" | "msteams" | "microsoft_teams" => Some(SourceKind::Teams),
            _ => None,
        }
    }
}

/// A selectable container within a source — a Slack channel or a Teams channel/chat. This is what
/// the user picks when choosing *what* to import (deliberate, scoped, never the whole workspace).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Channel {
    /// Provider-native id (channel id / conversation id). Stable; used for idempotent import.
    pub id: String,
    /// Display name (e.g. `#architecture`, or a chat topic).
    pub name: String,
    /// Optional one-line purpose/topic to help the user choose.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub purpose: Option<String>,
    /// Approximate member count, when the provider reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub member_count: Option<u64>,
}

/// One normalized message — the atomic unit of imported knowledge, with full provenance.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    /// Provider-native message id / timestamp id. Unique within a channel; drives dedup.
    pub id: String,
    /// The thread this message belongs to (the parent's id), if any. Root messages: `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    /// Display name of the author, when resolvable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    /// Message body, already converted to plain Markdown-ish text.
    pub text: String,
    /// Authoring time (RFC3339), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    /// A deep link back to the original message, when the provider supplies one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permalink: Option<String>,
}

/// The scope of a single import request — deliberately explicit, never "everything".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportScope {
    /// Channels the user chose to import.
    pub channel_ids: Vec<String>,
    /// Optional lower bound (RFC3339) — only messages at/after this instant. `None` = provider
    /// default window (a bounded recent page, never an unbounded backfill).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    /// Max messages to pull per channel — a hard privacy/rate guard.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_messages: Option<usize>,
}

/// The outcome of an import — surfaced to the user so it's clear what was brought in.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportSummary {
    /// Channels successfully imported.
    pub channels_imported: usize,
    /// New messages written (after dedup).
    pub messages_imported: usize,
    /// Messages skipped as already-present (idempotent re-import).
    pub messages_skipped: usize,
    /// Markdown documents written/updated in the vault.
    pub documents_written: usize,
    /// Per-channel or per-stage failures that did not abort the whole import (partial success).
    pub warnings: Vec<String>,
}

/// A connected source as remembered by the engine — **metadata only, never a token**.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectedSource {
    pub kind: SourceKind,
    /// A friendly workspace/tenant label the user recognizes (e.g. `acme.slack.com`).
    pub workspace: String,
    /// Where imported notes for this source live under the vault (relative), so the user can find
    /// and delete them.
    pub folder: String,
    /// RFC3339 of the last successful import, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_imported_at: Option<String>,
    /// Cumulative documents on disk for this source.
    #[serde(default)]
    pub document_count: usize,
    /// Channel names imported so far (for the "what was imported" summary).
    #[serde(default)]
    pub imported_channels: Vec<String>,
}
