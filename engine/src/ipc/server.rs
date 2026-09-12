//! Transport-agnostic IPC server.
//!
//! The concrete transport (stdio pipe, local socket, etc.) is chosen per platform and
//! kept behind this type so the pipeline never depends on how bytes reach the app.
//!
//! TODO(v0): bind a transport, deserialize [`protocol::Envelope`]s, dispatch each
//! [`protocol::Request`] into `pipeline`, and stream [`events::Event`]s back.

use super::protocol::{Request, Response};

/// Owns the transport and routes requests into the engine's pipeline.
#[derive(Default)]
pub struct Server;

impl Server {
    pub fn new() -> Self {
        Server
    }

    /// Handle a single decoded request. Placeholder routing for the scaffold.
    pub fn handle(&self, request: Request) -> Response {
        match request {
            // TODO: create a job, hand it to the pipeline orchestrator, return its id.
            Request::StartMeeting { .. } | Request::ImportMeeting { .. } => Response::Error {
                message: "not implemented".to_string(),
            },
            // TODO: read from storage and return serialized domain data.
            Request::GetMeeting { .. } | Request::GetTranscript { .. } | Request::GetMom { .. } => {
                Response::Error {
                    message: "not implemented".to_string(),
                }
            }
            // TODO: signal cancellation to the running job.
            Request::CancelJob { .. } => Response::Error {
                message: "not implemented".to_string(),
            },
        }
    }
}
