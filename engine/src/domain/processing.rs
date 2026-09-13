//! Processing state: durable, operational metadata about a capture's AI enrichment.
//!
//! This is the backbone of Notely's reliability promise — **AI can fail; your knowledge cannot**.
//! The source of truth (a meeting's transcript) is persisted *before* any AI runs, so this status
//! never gates whether the capture is safe. It only records how far enrichment got, so an
//! interrupted or failed run can be surfaced calmly and retried later.
//!
//! It is stored *separately* from the [`Meeting`](crate::domain::Meeting) (as its own artifact),
//! keeping the portable domain model clean of operational concerns.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::domain::Meeting;

/// A captured meeting paired with its enrichment status — the unit the Inbox and recovery UI list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MeetingSummary {
    pub meeting: Meeting,
    /// `None` for meetings captured before processing status existed (treated as already `Ready`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<ProcessingStatus>,
}

/// Where a capture's AI enrichment currently stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingState {
    /// Enrichment is in flight (or was, before an interruption).
    Processing,
    /// Enrichment finished; derived artifacts (IR, MOM) are available.
    Ready,
    /// Enrichment did not finish, but can be retried (the source is safe).
    Deferred,
    /// Enrichment failed in a way that needs attention before retrying is useful.
    Failed,
}

/// Whether a failure is worth retrying automatically/by one click, or needs user action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    /// A runtime/model/network problem (e.g. the LLM was unavailable). Retrying may succeed.
    Temporary,
    /// Not retryable as-is (e.g. persistence failure); surfacing it beats silently retrying.
    Permanent,
}

/// The persisted processing status for one capture. `updated_at` lets the UI show recency and lets
/// recovery reason about staleness.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessingStatus {
    pub state: ProcessingState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_kind: Option<FailureKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub updated_at: DateTime<Utc>,
}

impl ProcessingStatus {
    pub fn processing() -> Self {
        Self::at(ProcessingState::Processing, None, None)
    }

    pub fn ready() -> Self {
        Self::at(ProcessingState::Ready, None, None)
    }

    /// A retryable failure: the source is safe; enrichment can be re-run.
    pub fn deferred(error: impl Into<String>) -> Self {
        Self::at(
            ProcessingState::Deferred,
            Some(FailureKind::Temporary),
            Some(error.into()),
        )
    }

    /// A non-retryable failure that needs attention.
    pub fn failed(error: impl Into<String>) -> Self {
        Self::at(
            ProcessingState::Failed,
            Some(FailureKind::Permanent),
            Some(error.into()),
        )
    }

    fn at(
        state: ProcessingState,
        failure_kind: Option<FailureKind>,
        error: Option<String>,
    ) -> Self {
        Self {
            state,
            failure_kind,
            error,
            updated_at: Utc::now(),
        }
    }

    /// Whether a one-click retry makes sense: anything deferred, plus temporary failures.
    pub fn is_retryable(&self) -> bool {
        matches!(self.state, ProcessingState::Deferred)
            || (matches!(self.state, ProcessingState::Failed)
                && self.failure_kind == Some(FailureKind::Temporary))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deferred_is_retryable_failed_is_not() {
        assert!(ProcessingStatus::deferred("llm offline").is_retryable());
        assert!(!ProcessingStatus::failed("disk full").is_retryable());
        assert!(!ProcessingStatus::ready().is_retryable());
        assert!(!ProcessingStatus::processing().is_retryable());
    }

    #[test]
    fn serializes_snake_case() {
        let json = serde_json::to_string(&ProcessingStatus::deferred("x")).unwrap();
        assert!(json.contains("\"deferred\""));
        assert!(json.contains("\"temporary\""));
    }
}
