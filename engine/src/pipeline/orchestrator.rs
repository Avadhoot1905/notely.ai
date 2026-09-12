//! Drives a meeting through every processing stage and emits progress events.
//!
//! The orchestrator depends on the *abstractions* exposed by each module (an ASR provider,
//! an AI provider, a renderer, storage) — never on a concrete backend like Whisper or Ollama.
//! This keeps the ordering logic stable while implementations are swapped underneath.

/// Coordinates the stages for a single meeting. Fields (provider handles, storage, event
/// sink) will be injected here as the modules are implemented.
#[derive(Default)]
pub struct Orchestrator;

impl Orchestrator {
    pub fn new() -> Self {
        Orchestrator
    }

    /// Run the full pipeline for one meeting.
    ///
    /// TODO(v0): media → ASR → transcript processing → AI extraction → AI synthesis →
    /// MeetingIR validation → rendering → storage, emitting `ipc::events::Event`s throughout.
    pub fn process(&self /* , input, providers, event_sink */) {
        // Intentionally unimplemented — stage wiring lands as modules are built.
    }
}
