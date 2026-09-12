//! Voice-activity detection: split audio into speech regions so ASR skips silence and
//! long meetings can be chunked deterministically.
//!
//! TODO(v0): integrate a VAD implementation and return speech time-ranges.
