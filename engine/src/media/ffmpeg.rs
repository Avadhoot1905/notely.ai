//! FFmpeg integration: decode/resample arbitrary audio (or video) into the mono PCM/WAV
//! format the ASR stage expects.
//!
//! TODO(v0): shell out to (or bind) FFmpeg to extract normalized audio. Flutter must never
//! touch FFmpeg directly — this stays entirely inside the engine.
