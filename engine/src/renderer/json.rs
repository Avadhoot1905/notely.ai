//! Render a [`MeetingIr`] to canonical JSON.
//!
//! A direct, stable serialization of the IR — the machine-readable output other tools consume.
//! No LLM involved.

use crate::domain::MeetingIr;

/// Serialize the IR to pretty JSON.
pub fn render(ir: &MeetingIr) -> Result<String, serde_json::Error> {
    serde_json::to_string_pretty(ir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_json() {
        let ir = MeetingIr {
            summary: "hi".into(),
            ..Default::default()
        };
        let text = render(&ir).unwrap();
        let back: MeetingIr = serde_json::from_str(&text).unwrap();
        assert_eq!(ir, back);
    }
}
