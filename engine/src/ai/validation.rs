//! Validation: check a candidate [`crate::domain::MeetingIr`] for structural consistency and
//! evidence coverage before it is rendered or stored. This is the optional "verified" quality
//! pass — deterministic checks where possible, an LLM critique pass where language judgement
//! is required.
//!
//! TODO(v0): implement schema/consistency checks and an optional LLM verification stage.
