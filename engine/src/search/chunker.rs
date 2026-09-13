//! Deterministic Markdown chunking for retrieval.
//!
//! Notes are split into passages small enough to rank and cite precisely, but large enough to
//! carry meaning. Chunking groups whole paragraphs (blank-line-separated blocks) up to a
//! character budget, and — crucially — tracks the exact 0-based, inclusive line range each chunk
//! spans, so a citation can open the source note and highlight precisely what an answer drew from.
//!
//! Like `preprocess`, this is plain deterministic Rust: no model ever decides where a chunk
//! begins or what a passage "means".

/// A retrievable passage of a note, tagged with its position in the source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// 0-based, inclusive line range within the source file.
    pub start_line: usize,
    pub end_line: usize,
    /// The passage text (original lines joined with `\n`).
    pub text: String,
}

/// Default passage budget in characters. ~300 tokens: small enough to rank and cite tightly,
/// large enough to keep a paragraph or two of context together.
pub const DEFAULT_CHUNK_CHARS: usize = 1_200;

/// Split `text` into passages of at most ~`max_chars`, preserving line ranges.
///
/// Blank lines delimit paragraphs and are never included at a chunk boundary, but a chunk's range
/// still spans any blank lines *between* the paragraphs it contains, so highlight-on-click covers
/// the whole passage as written.
pub fn chunk_markdown(text: &str, max_chars: usize) -> Vec<Chunk> {
    let budget = max_chars.max(1);
    let lines: Vec<&str> = text.split('\n').collect();
    let mut chunks = Vec::new();

    // The lines accumulated into the current chunk, as (index, text).
    let mut cur: Vec<(usize, &str)> = Vec::new();
    let mut cur_chars = 0usize;

    let flush = |cur: &mut Vec<(usize, &str)>, chunks: &mut Vec<Chunk>| {
        if cur.is_empty() {
            return;
        }
        let start = cur.first().unwrap().0;
        let end = cur.last().unwrap().0;
        let text = cur.iter().map(|(_, l)| *l).collect::<Vec<_>>().join("\n");
        chunks.push(Chunk {
            start_line: start,
            end_line: end,
            text,
        });
        cur.clear();
    };

    let mut i = 0usize;
    while i < lines.len() {
        // Skip blank lines between paragraphs.
        if lines[i].trim().is_empty() {
            i += 1;
            continue;
        }
        // Gather one paragraph (consecutive non-blank lines).
        let para_start = i;
        while i < lines.len() && !lines[i].trim().is_empty() {
            i += 1;
        }
        let para: Vec<(usize, &str)> = (para_start..i).map(|k| (k, lines[k])).collect();
        let para_chars: usize = para.iter().map(|(_, l)| l.len() + 1).sum();

        // Once the current chunk is non-empty and the next paragraph would overflow the budget,
        // flush it and start fresh. (A single oversized paragraph still becomes one chunk.)
        if cur_chars > 0 && cur_chars + para_chars > budget {
            flush(&mut cur, &mut chunks);
            cur_chars = 0;
        }
        cur.extend(para);
        cur_chars += para_chars;
    }
    flush(&mut cur, &mut chunks);
    chunks
}

/// The first Markdown heading in `text` (its `#…` text), if any — used as a note's display title.
pub fn first_heading(text: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix('#') {
            let title = rest.trim_start_matches('#').trim();
            if !title.is_empty() {
                return Some(title.to_string());
            }
        }
    }
    None
}

/// Collapse a passage into a single-line preview of at most `max` characters.
pub fn snippet(text: &str, max: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // Strip a leading heading marker for readability.
    let collapsed = collapsed.trim_start_matches('#').trim_start().to_string();
    if collapsed.chars().count() > max {
        let truncated: String = collapsed.chars().take(max).collect();
        format!("{}…", truncated.trim_end())
    } else {
        collapsed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_paragraphs_and_tracks_line_ranges() {
        let text = "# Title\n\nFirst paragraph line one.\nline two.\n\nSecond paragraph.";
        let chunks = chunk_markdown(text, 10_000);
        // Everything fits in one chunk; the range spans line 0..=5 (including the blank lines).
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].start_line, 0);
        assert_eq!(chunks[0].end_line, 5);
    }

    #[test]
    fn splits_when_budget_exceeded() {
        let a = "A".repeat(80);
        let b = "B".repeat(80);
        let text = format!("{a}\n\n{b}");
        let chunks = chunk_markdown(&text, 100);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].start_line, 0);
        assert_eq!(chunks[0].end_line, 0);
        assert_eq!(chunks[1].start_line, 2);
        assert_eq!(chunks[1].end_line, 2);
    }

    #[test]
    fn empty_text_yields_no_chunks() {
        assert!(chunk_markdown("", 100).is_empty());
        assert!(chunk_markdown("\n\n   \n", 100).is_empty());
    }

    #[test]
    fn first_heading_and_snippet() {
        assert_eq!(
            first_heading("text\n## Real Heading\n"),
            Some("Real Heading".into())
        );
        assert_eq!(first_heading("no heading here"), None);
        assert_eq!(snippet("#  Hello    world  ", 100), "Hello world");
        assert_eq!(snippet(&"x ".repeat(200), 5), "x x x…");
    }
}
