//! Source-grounded question answering over the vault.
//!
//! The flow is deliberately simple and honest: retrieve the most relevant passages, hand *only*
//! those to the local LLM, and ask it to answer citing them by number. The passages become the
//! answer's [`Citation`]s regardless of what the model writes, so every answer stays traceable to
//! real, user-owned source material — Notely behaves like an intelligence layer over the vault,
//! not a chatbot with opinions.
//!
//! Reliability is a first-class concern (see the product's "AI failure must not equal data loss"
//! rule): if the LLM is unreachable or errors, [`answer`] still returns the retrieved passages as
//! a plain, useful list. Ask degrades; it never dies.

use crate::domain::{AskAnswer, Citation};
use crate::llm::{GenerateRequest, LlmProvider};

use super::index::Passage;

/// How many passages to ground an answer in. Small enough to fit a 1.7B context; large enough to
/// span a couple of related notes.
pub const DEFAULT_TOP_K: usize = 6;

/// Answer `question` using only `passages`. Never fails: on an LLM error it returns a deterministic
/// summary of the sources so the user still gets useful, cited results.
pub async fn answer(question: &str, passages: &[Passage], llm: &dyn LlmProvider) -> AskAnswer {
    let citations: Vec<Citation> = passages
        .iter()
        .map(|p| Citation {
            path: p.path.clone(),
            start_line: p.start_line,
            end_line: p.end_line,
            snippet: passage_preview(&p.body),
        })
        .collect();
    let files_read = unique_paths(&citations);

    if passages.is_empty() {
        return AskAnswer {
            text: format!(
                "I couldn't find anything about **{}** in this vault.\n\nTry different keywords, \
                 or add a note about it.",
                question.trim()
            ),
            files_read,
            citations,
        };
    }

    let request = GenerateRequest::new(build_prompt(question, passages))
        .with_system(SYSTEM_PROMPT)
        .with_temperature(0.2);

    match llm.generate(request).await {
        Ok(resp) => {
            let text = clean_answer(&resp.text);
            let text = if text.is_empty() {
                fallback_text(question, &citations)
            } else {
                text
            };
            AskAnswer {
                text,
                files_read,
                citations,
            }
        }
        // LLM down/erroring: still answer usefully from the retrieved sources.
        Err(_) => AskAnswer {
            text: fallback_text(question, &citations),
            files_read,
            citations,
        },
    }
}

const SYSTEM_PROMPT: &str = "You are Notely, answering questions strictly from the user's own \
notes. Use ONLY the numbered sources provided. Support every claim with a citation marker like \
[1] or [2] that refers to the source it came from. If the sources do not contain the answer, say \
so plainly. Never invent facts, names, dates, or sources. Answer concisely in Markdown.";

fn build_prompt(question: &str, passages: &[Passage]) -> String {
    let mut out = String::new();
    out.push_str("Question: ");
    out.push_str(question.trim());
    out.push_str("\n\nSources:\n");
    for (i, p) in passages.iter().enumerate() {
        let n = i + 1;
        let lines = if p.start_line == p.end_line {
            format!("line {}", p.start_line + 1)
        } else {
            format!("lines {}-{}", p.start_line + 1, p.end_line + 1)
        };
        out.push_str(&format!(
            "[{n}] {} ({lines}):\n{}\n\n",
            p.title,
            p.body.trim()
        ));
    }
    out.push_str("Answer the question using only these sources, citing them by number (e.g. [1]).");
    out
}

/// Strip `<think>…</think>` blocks some reasoning models emit before the answer.
fn clean_answer(text: &str) -> String {
    let mut s = text.trim().to_string();
    while let Some(start) = s.find("<think>") {
        if let Some(end) = s[start..].find("</think>") {
            let end = start + end + "</think>".len();
            s.replace_range(start..end, "");
        } else {
            s.truncate(start);
            break;
        }
    }
    s.trim().to_string()
}

/// Deterministic, LLM-free answer: list the sources found. Used when the model is unavailable.
fn fallback_text(question: &str, citations: &[Citation]) -> String {
    let mut b = String::new();
    b.push_str(&format!(
        "Here's what I found in your notes about **{}**:\n\n",
        question.trim()
    ));
    for (i, c) in citations.iter().enumerate() {
        b.push_str(&format!("- {} [{}]\n", lead(&c.snippet), i + 1));
    }
    b.push_str("\nClick a citation to open the exact passage.");
    b
}

/// A short leading fragment of a snippet for the fallback bullet list.
fn lead(snippet: &str) -> String {
    let s = snippet.trim();
    if s.chars().count() > 150 {
        let cut: String = s.chars().take(150).collect();
        format!("{}…", cut.trim_end())
    } else {
        s.to_string()
    }
}

fn passage_preview(body: &str) -> String {
    super::chunker::snippet(body, 240)
}

fn unique_paths(citations: &[Citation]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for c in citations {
        if seen.insert(c.path.clone()) {
            out.push(c.path.clone());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{GenerateResponse, LlmError};
    use async_trait::async_trait;

    struct DownLlm;
    #[async_trait]
    impl LlmProvider for DownLlm {
        async fn generate(&self, _r: GenerateRequest) -> Result<GenerateResponse, LlmError> {
            Err(LlmError::Transport("offline".into()))
        }
        async fn health(&self) -> Result<(), LlmError> {
            Err(LlmError::Transport("offline".into()))
        }
    }

    struct EchoLlm;
    #[async_trait]
    impl LlmProvider for EchoLlm {
        async fn generate(&self, _r: GenerateRequest) -> Result<GenerateResponse, LlmError> {
            Ok(GenerateResponse {
                text: "<think>hmm</think>PostgreSQL was chosen [1].".into(),
                model: "test".into(),
            })
        }
        async fn health(&self) -> Result<(), LlmError> {
            Ok(())
        }
    }

    fn passage(path: &str) -> Passage {
        Passage {
            path: path.into(),
            title: "Architecture".into(),
            start_line: 2,
            end_line: 4,
            body: "We decided to use PostgreSQL for Project X.".into(),
        }
    }

    #[tokio::test]
    async fn empty_passages_reports_nothing_found_without_calling_llm() {
        let ans = answer("database migration", &[], &EchoLlm).await;
        assert!(ans.citations.is_empty());
        assert!(ans.text.contains("couldn't find"));
    }

    #[tokio::test]
    async fn llm_answer_is_cleaned_and_cited() {
        let ans = answer("what db?", &[passage("/n/arch.md")], &EchoLlm).await;
        assert_eq!(ans.text, "PostgreSQL was chosen [1].");
        assert_eq!(ans.citations.len(), 1);
        assert_eq!(ans.files_read, vec!["/n/arch.md".to_string()]);
    }

    #[tokio::test]
    async fn falls_back_to_source_list_when_llm_down() {
        let ans = answer("what db?", &[passage("/n/arch.md")], &DownLlm).await;
        assert!(ans.text.contains("[1]"));
        assert!(ans.text.contains("PostgreSQL"));
        assert_eq!(ans.citations.len(), 1);
    }

    #[tokio::test]
    async fn files_read_dedupes_preserving_order() {
        let ps = vec![passage("/a.md"), passage("/b.md"), passage("/a.md")];
        let ans = answer("q", &ps, &DownLlm).await;
        assert_eq!(
            ans.files_read,
            vec!["/a.md".to_string(), "/b.md".to_string()]
        );
    }
}
