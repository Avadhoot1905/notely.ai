//! Render a [`MeetingIr`] to a Markdown MOM document.
//!
//! Fully deterministic templating — the same IR always yields the same bytes. An LLM is NEVER used
//! to format the MOM. Section order matches the field order of [`MeetingIr`].

use std::fmt::Write as _;

use crate::domain::{Evidence, MeetingIr};

/// Render the IR as a Markdown string.
pub fn render(ir: &MeetingIr) -> String {
    render_with_title(ir, "Meeting")
}

/// Render with an explicit document title (e.g. the meeting title).
pub fn render_with_title(ir: &MeetingIr, title: &str) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "# {title}\n");

    // Summary
    let _ = writeln!(out, "## Summary\n");
    if ir.summary.trim().is_empty() {
        let _ = writeln!(out, "_No summary._\n");
    } else {
        let _ = writeln!(out, "{}\n", ir.summary.trim());
    }

    // Participants
    let _ = writeln!(out, "## Participants\n");
    if ir.participants.is_empty() {
        let _ = writeln!(out, "_None identified._\n");
    } else {
        for p in &ir.participants {
            match &p.display_name {
                Some(name) => {
                    let _ = writeln!(out, "- {name} (`{}`)", p.id);
                }
                None => {
                    let _ = writeln!(out, "- `{}`", p.id);
                }
            }
        }
        out.push('\n');
    }

    // Topics
    let _ = writeln!(out, "## Topics\n");
    if ir.topics.is_empty() {
        let _ = writeln!(out, "_None._\n");
    } else {
        for t in &ir.topics {
            let _ = writeln!(out, "### {}\n", t.title.trim());
            if let Some(s) = &t.summary {
                if !s.trim().is_empty() {
                    let _ = writeln!(out, "{}\n", s.trim());
                }
            }
            write_evidence_quotes(&mut out, &t.evidence);
        }
    }

    // Decisions
    let _ = writeln!(out, "## Decisions\n");
    if ir.decisions.is_empty() {
        let _ = writeln!(out, "_None recorded._\n");
    } else {
        for d in &ir.decisions {
            let _ = writeln!(out, "- **{}**", d.decision.trim());
            if let Some(ctx) = &d.context {
                if !ctx.trim().is_empty() {
                    let _ = writeln!(out, "  - Context: {}", ctx.trim());
                }
            }
            write_evidence_inline(&mut out, &d.evidence);
        }
        out.push('\n');
    }

    // Action items — a stable table.
    let _ = writeln!(out, "## Action Items\n");
    if ir.action_items.is_empty() {
        let _ = writeln!(out, "_None._\n");
    } else {
        let _ = writeln!(out, "| Action | Owner | Deadline | Status |");
        let _ = writeln!(out, "|--------|-------|----------|--------|");
        for a in &ir.action_items {
            let _ = writeln!(
                out,
                "| {} | {} | {} | {} |",
                cell(&a.description),
                cell(a.owner.as_deref().unwrap_or("—")),
                cell(a.deadline.as_deref().unwrap_or("—")),
                status_label(a.status),
            );
        }
        out.push('\n');
    }

    // Open questions
    let _ = writeln!(out, "## Open Questions\n");
    if ir.open_questions.is_empty() {
        let _ = writeln!(out, "_None._\n");
    } else {
        for q in &ir.open_questions {
            let _ = writeln!(out, "- {}", q.question.trim());
            write_evidence_inline(&mut out, &q.evidence);
        }
        out.push('\n');
    }

    // Risks
    let _ = writeln!(out, "## Risks\n");
    if ir.risks.is_empty() {
        let _ = writeln!(out, "_None._\n");
    } else {
        for r in &ir.risks {
            match &r.severity {
                Some(sev) if !sev.trim().is_empty() => {
                    let _ = writeln!(out, "- **[{}]** {}", sev.trim(), r.description.trim());
                }
                _ => {
                    let _ = writeln!(out, "- {}", r.description.trim());
                }
            }
            write_evidence_inline(&mut out, &r.evidence);
        }
        out.push('\n');
    }

    // Normalize trailing whitespace for deterministic output.
    while out.ends_with('\n') {
        out.pop();
    }
    out.push('\n');
    out
}

fn status_label(status: crate::domain::ActionStatus) -> &'static str {
    use crate::domain::ActionStatus::*;
    match status {
        Open => "open",
        InProgress => "in progress",
        Done => "done",
        Cancelled => "cancelled",
    }
}

/// Escape a table cell: collapse newlines and escape pipes so the table stays well-formed.
fn cell(s: &str) -> String {
    s.trim().replace('\n', " ").replace('|', "\\|")
}

/// True if any evidence entry has a non-empty quote (provenance-only markers are skipped in prose).
fn write_evidence_quotes(out: &mut String, evidence: &[Evidence]) {
    for e in evidence {
        if e.quote.trim().is_empty() {
            continue;
        }
        let _ = writeln!(out, "> {}\n", e.quote.trim());
    }
}

fn write_evidence_inline(out: &mut String, evidence: &[Evidence]) {
    for e in evidence {
        if e.quote.trim().is_empty() {
            continue;
        }
        let _ = writeln!(out, "  - _evidence:_ \"{}\"", e.quote.trim());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{ActionItem, Decision, Evidence, MeetingIr};

    fn sample() -> MeetingIr {
        MeetingIr {
            summary: "Planned the v0 launch.".into(),
            decisions: vec![Decision {
                decision: "Ship behind a flag".into(),
                evidence: vec![Evidence {
                    quote: "let's flag it".into(),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            action_items: vec![ActionItem {
                description: "Write migration".into(),
                owner: Some("Avi".into()),
                deadline: Some("Friday".into()),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn renders_all_sections_deterministically() {
        let ir = sample();
        let a = render_with_title(&ir, "Planning");
        let b = render_with_title(&ir, "Planning");
        assert_eq!(a, b, "rendering must be deterministic");
        for section in [
            "# Planning",
            "## Summary",
            "## Participants",
            "## Topics",
            "## Decisions",
            "## Action Items",
            "## Open Questions",
            "## Risks",
        ] {
            assert!(a.contains(section), "missing section: {section}");
        }
    }

    #[test]
    fn action_items_render_as_a_table() {
        let out = render_with_title(&sample(), "Planning");
        assert!(out.contains("| Action | Owner | Deadline | Status |"));
        assert!(out.contains("| Write migration | Avi | Friday | open |"));
    }

    #[test]
    fn missing_owner_and_deadline_render_as_dashes_not_invented() {
        let ir = MeetingIr {
            summary: "s".into(),
            action_items: vec![ActionItem {
                description: "do it".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let out = render(&ir);
        assert!(out.contains("| do it | — | — | open |"));
    }

    #[test]
    fn empty_ir_renders_placeholders_not_panics() {
        let out = render(&MeetingIr::default());
        assert!(out.contains("_No summary._"));
        assert!(out.ends_with('\n'));
    }
}
