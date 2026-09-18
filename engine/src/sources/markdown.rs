//! Normalize imported messages into provenance-bearing Markdown — the bridge into Notely's vault.
//!
//! Imported knowledge becomes ordinary Markdown notes (one per channel) so it flows through the
//! *existing* index → Search → Ask → citation pipeline unchanged, shows up in the file tree, and is
//! removed by simply deleting the file. Provenance lives in YAML frontmatter and in each message
//! block (workspace, channel, author, time, permalink, thread), so a citation can always name the
//! exact Slack/Teams origin. Rendering is deterministic — no model formats anything.

use super::model::{Message, SourceKind};

/// Frontmatter + heading for a channel note, written once when the file is first created.
pub fn channel_header(
    kind: SourceKind,
    workspace: &str,
    channel_name: &str,
    channel_id: &str,
    imported_at: &str,
) -> String {
    let mut s = String::new();
    s.push_str("---\n");
    s.push_str(&format!("notely_source: {}\n", kind.tag()));
    s.push_str(&format!("workspace: {}\n", yaml_scalar(workspace)));
    s.push_str(&format!("channel: {}\n", yaml_scalar(channel_name)));
    s.push_str(&format!("channel_id: {}\n", yaml_scalar(channel_id)));
    s.push_str(&format!("imported_at: {imported_at}\n"));
    s.push_str("---\n\n");
    s.push_str(&format!("# {} · {}\n\n", kind.label(), channel_name));
    s.push_str(&format!(
        "> Imported knowledge from the **{}** {} workspace. Each message links back to its \
         original; this note is searchable and citable alongside your other notes.\n",
        workspace,
        kind.label()
    ));
    s
}

/// Render one message as a Markdown block appended to its channel note. Deterministic and
/// self-contained: author, time, a thread marker, the body, and a source link.
pub fn message_block(kind: SourceKind, msg: &Message) -> String {
    let author = msg.author.as_deref().unwrap_or("Unknown");
    let when = msg
        .timestamp
        .as_deref()
        .map(friendly_time)
        .unwrap_or_default();
    let mut head = format!("**{author}**");
    if !when.is_empty() {
        head.push_str(&format!(" · {when}"));
    }
    if msg.thread_id.is_some() {
        head.push_str(" · ↳ reply in thread");
    }
    if let Some(link) = &msg.permalink {
        head.push_str(&format!(" · [open in {}]({})", kind.label(), link));
    }
    let body = msg.text.trim();
    format!("\n### {head}\n\n{body}\n")
}

/// Sanitize a channel name into a safe, readable file stem.
pub fn safe_stem(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | ' ' => c,
            '/' | '\\' | ':' => '-',
            _ => '-',
        })
        .collect();
    let collapsed = cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches('-')
        .to_string();
    if collapsed.is_empty() {
        "channel".to_string()
    } else {
        collapsed
    }
}

/// A compact human time from an RFC3339 timestamp; falls back to the raw string.
fn friendly_time(ts: &str) -> String {
    chrono::DateTime::parse_from_rfc3339(ts)
        .map(|dt| dt.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|_| ts.to_string())
}

/// Escape a YAML scalar minimally (quote when it could be misparsed).
fn yaml_scalar(s: &str) -> String {
    if s.is_empty()
        || s.contains(':')
        || s.contains('#')
        || s.starts_with(['-', '[', '{', '"', '\''])
    {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_stem_is_filesystem_safe() {
        assert_eq!(safe_stem("#architecture"), "architecture");
        assert_eq!(
            safe_stem("Engineering / Architecture"),
            "Engineering - Architecture"
        );
        assert_eq!(safe_stem(""), "channel");
    }

    #[test]
    fn message_block_carries_provenance() {
        let msg = Message {
            id: "1".into(),
            thread_id: Some("t".into()),
            author: Some("Ada".into()),
            text: "We chose TLS proxy.".into(),
            timestamp: Some("2021-01-01T12:00:00Z".into()),
            permalink: Some("https://acme.slack.com/archives/C1/p1".into()),
        };
        let block = message_block(SourceKind::Slack, &msg);
        assert!(block.contains("**Ada**"));
        assert!(block.contains("2021-01-01 12:00"));
        assert!(block.contains("reply in thread"));
        assert!(block.contains("open in Slack"));
        assert!(block.contains("We chose TLS proxy."));
    }

    #[test]
    fn header_has_frontmatter_and_heading() {
        let h = channel_header(
            SourceKind::Slack,
            "Acme",
            "architecture",
            "C1",
            "2026-01-01T00:00:00Z",
        );
        assert!(h.starts_with("---\n"));
        assert!(h.contains("notely_source: slack"));
        assert!(h.contains("# Slack · architecture"));
    }
}
