//! The persistence-facing interface used by the pipeline/IPC layers.
//!
//! Callers depend on the [`Store`] trait and `domain` types — never on SQL, table layouts, or file
//! paths. The concrete backend (see [`super::database`]) is an implementation detail. For v0 a
//! single `Store` trait is enough; it can be split into narrower repositories later if needed.

use async_trait::async_trait;

use crate::domain::{Meeting, MeetingId, MeetingIr, ProcessingStatus, Transcript};

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("storage backend error: {0}")]
    Backend(String),
    #[error("failed to (de)serialize stored data: {0}")]
    Serde(String),
}

/// Local persistence for meetings and their artifacts (transcript, IR, rendered MOM).
#[async_trait]
pub trait Store: Send + Sync {
    async fn save_meeting(&self, meeting: &Meeting) -> Result<(), StorageError>;
    async fn get_meeting(&self, id: &MeetingId) -> Result<Option<Meeting>, StorageError>;
    async fn list_meetings(&self) -> Result<Vec<Meeting>, StorageError>;

    async fn save_transcript(
        &self,
        id: &MeetingId,
        transcript: &Transcript,
    ) -> Result<(), StorageError>;
    async fn get_transcript(&self, id: &MeetingId) -> Result<Option<Transcript>, StorageError>;

    async fn save_meeting_ir(&self, id: &MeetingId, ir: &MeetingIr) -> Result<(), StorageError>;
    async fn get_meeting_ir(&self, id: &MeetingId) -> Result<Option<MeetingIr>, StorageError>;

    /// Persist a rendered MOM (e.g. Markdown) for a meeting.
    async fn save_mom(&self, id: &MeetingId, mom: &str) -> Result<(), StorageError>;
    async fn get_mom(&self, id: &MeetingId) -> Result<Option<String>, StorageError>;

    /// Persist the AI-enrichment [`ProcessingStatus`] for a meeting. This is operational metadata,
    /// stored separately from the source so it never affects source safety.
    async fn save_processing_status(
        &self,
        id: &MeetingId,
        status: &ProcessingStatus,
    ) -> Result<(), StorageError>;
    async fn get_processing_status(
        &self,
        id: &MeetingId,
    ) -> Result<Option<ProcessingStatus>, StorageError>;
    /// All persisted processing statuses, keyed by meeting id. Powers recovery and the Inbox.
    async fn list_processing_statuses(
        &self,
    ) -> Result<Vec<(MeetingId, ProcessingStatus)>, StorageError>;
}
