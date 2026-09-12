//! Automatic speech recognition (ASR).
//!
//! The pipeline talks to an [`provider::AsrProvider`] abstraction, never directly to Whisper.
//! A concrete backend (Whisper is the first) implements the trait so other engines can be
//! added later without touching the pipeline.
//!
//! ```text
//! AsrProvider
//!   ├── Whisper (v0)
//!   └── future providers
//! ```

pub mod provider;
pub mod whisper;

pub use provider::AsrProvider;
