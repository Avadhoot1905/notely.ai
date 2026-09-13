//! Retrieval + question-answering concepts: the vault-wide "knowledge" surface.
//!
//! These types are the portable shape of *source-aware retrieval* over the user's own material.
//! A [`SearchHit`] is a ranked passage; a [`Citation`] is the same passage once an [`AskAnswer`]
//! draws on it. Every answer is grounded: it can only cite passages that actually exist in the
//! vault, so AI-derived knowledge stays traceable to user-owned source material.
//!
//! Like the rest of `domain`, these depend on nothing but `serde`. Line indices are 0-based and
//! inclusive so the Flutter editor can select and highlight the exact passage on click (it renders
//! them 1-based for humans).

use serde::{Deserialize, Serialize};

/// A ranked passage matched by a search query.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    /// Absolute path of the source note the passage lives in.
    pub path: String,
    /// A human-friendly label for the source (its first heading, else the file name).
    pub title: String,
    /// 0-based, inclusive line range of the passage within the file.
    pub start_line: usize,
    pub end_line: usize,
    /// A trimmed, single-line preview of the passage.
    pub snippet: String,
}

/// A pointer into a note: the passage an [`AskAnswer`] draws from. Mirrors the Flutter `Citation`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Citation {
    /// Absolute path of the cited note.
    pub path: String,
    /// 0-based, inclusive line range the answer is grounded in.
    pub start_line: usize,
    pub end_line: usize,
    /// A trimmed preview of the cited passage.
    pub snippet: String,
}

impl From<SearchHit> for Citation {
    fn from(h: SearchHit) -> Self {
        Citation {
            path: h.path,
            start_line: h.start_line,
            end_line: h.end_line,
            snippet: h.snippet,
        }
    }
}

/// A source-grounded answer: prose plus the exact passages it is built from.
///
/// The [`text`](Self::text) may contain `[n]` markers (1-based) that reference [`citations`](Self::citations),
/// which the desktop app renders as clickable chips that open the source at the right line.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AskAnswer {
    /// The answer body. `[n]` markers reference [`citations`](Self::citations) (1-based).
    pub text: String,
    /// Absolute paths of the notes the answer actually drew from, in first-cited order.
    pub files_read: Vec<String>,
    /// The passages backing the answer, in citation (`[n]`) order.
    pub citations: Vec<Citation>,
}
