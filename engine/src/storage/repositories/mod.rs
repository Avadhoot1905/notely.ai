//! Repository traits: the persistence-facing interface the pipeline/IPC layer uses to load
//! and save `domain` entities (meetings, transcripts, Meeting IR, rendered MOMs).
//!
//! Traits live here; concrete implementations bind them to [`super::Storage`]. Keeping them
//! abstract means callers never see the storage backend.
//!
//! TODO(v0): define `MeetingRepository`, `TranscriptRepository`, `MeetingIrRepository`.
