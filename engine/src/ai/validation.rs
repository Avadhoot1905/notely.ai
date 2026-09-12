//! Validation: check a candidate [`MeetingIr`] before it is accepted, rendered, or stored.
//!
//! Deterministic structural checks. Deserialization already guarantees types and required JSON
//! fields; this catches *semantic* emptiness (blank summary, empty decision text, an action item
//! with no description) that is well-typed but useless. Malformed output must never be silently
//! accepted as a valid Meeting IR.

use crate::domain::MeetingIr;

/// Run all checks, returning every problem found (not just the first).
pub fn validate(ir: &MeetingIr) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();

    if ir.summary.trim().is_empty() {
        errors.push("summary must not be empty".to_string());
    }

    for (i, d) in ir.decisions.iter().enumerate() {
        if d.decision.trim().is_empty() {
            errors.push(format!("decisions[{i}].decision must not be empty"));
        }
    }
    for (i, a) in ir.action_items.iter().enumerate() {
        if a.description.trim().is_empty() {
            errors.push(format!("action_items[{i}].description must not be empty"));
        }
    }
    for (i, t) in ir.topics.iter().enumerate() {
        if t.title.trim().is_empty() {
            errors.push(format!("topics[{i}].title must not be empty"));
        }
    }
    for (i, q) in ir.open_questions.iter().enumerate() {
        if q.question.trim().is_empty() {
            errors.push(format!("open_questions[{i}].question must not be empty"));
        }
    }
    for (i, r) in ir.risks.iter().enumerate() {
        if r.description.trim().is_empty() {
            errors.push(format!("risks[{i}].description must not be empty"));
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{ActionItem, Decision};

    #[test]
    fn accepts_a_well_formed_ir() {
        let ir = MeetingIr {
            summary: "A real summary.".into(),
            ..Default::default()
        };
        assert!(validate(&ir).is_ok());
    }

    #[test]
    fn rejects_empty_summary() {
        let ir = MeetingIr {
            summary: "   ".into(),
            ..Default::default()
        };
        let errs = validate(&ir).unwrap_err();
        assert!(errs.iter().any(|e| e.contains("summary")));
    }

    #[test]
    fn rejects_empty_nested_text() {
        let ir = MeetingIr {
            summary: "ok".into(),
            decisions: vec![Decision::default()],
            action_items: vec![ActionItem::default()],
            ..Default::default()
        };
        let errs = validate(&ir).unwrap_err();
        assert!(errs.iter().any(|e| e.contains("decisions[0]")));
        assert!(errs.iter().any(|e| e.contains("action_items[0]")));
    }
}
