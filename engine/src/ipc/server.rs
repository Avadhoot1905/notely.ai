//! IPC server.
//!
//! The transport is deliberately isolated here so it can be swapped without touching pipeline
//! logic. For v0 it is newline-delimited JSON over a loopback TCP socket — simple, cross-platform,
//! and easy to drive from tests or the Dart client. It is NOT an HTTP/web server; just a framed
//! message stream.
//!
//! Framing: each line is one JSON message.
//!   - Client → engine: a [`RequestEnvelope`].
//!   - Engine → client: a [`ResponseEnvelope`] (has `request_id`) or an
//!     [`EventEnvelope`](super::events::EventEnvelope) (has `event`).

use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

use crate::ipc::events::EventEnvelope;
use crate::ipc::protocol::{
    RequestEnvelope, RequestId, Response, ResponseEnvelope, PROTOCOL_VERSION,
};
use crate::Engine;

/// Serves IPC for an [`Engine`] over a pluggable transport.
pub struct Server {
    engine: Arc<Engine>,
}

impl Server {
    pub fn new(engine: Arc<Engine>) -> Self {
        Self { engine }
    }

    /// Accept connections until `shutdown` resolves. Each connection is handled concurrently.
    pub async fn serve<S>(&self, listener: TcpListener, shutdown: S) -> std::io::Result<()>
    where
        S: std::future::Future<Output = ()>,
    {
        tokio::pin!(shutdown);
        loop {
            tokio::select! {
                _ = &mut shutdown => {
                    tracing::info!("IPC server shutting down");
                    return Ok(());
                }
                accepted = listener.accept() => {
                    match accepted {
                        Ok((stream, peer)) => {
                            tracing::debug!("IPC client connected: {peer}");
                            let engine = self.engine.clone();
                            tokio::spawn(async move {
                                if let Err(e) = handle_connection(engine, stream).await {
                                    tracing::debug!("IPC connection ended: {e}");
                                }
                            });
                        }
                        Err(e) => tracing::warn!("accept error: {e}"),
                    }
                }
            }
        }
    }
}

/// Handle one client: forward events and serve request/response, both serialized through a single
/// writer task so lines never interleave.
async fn handle_connection(engine: Arc<Engine>, stream: TcpStream) -> std::io::Result<()> {
    let (read_half, mut write_half) = stream.into_split();

    // Single writer: everything outbound goes through this channel.
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        while let Some(line) = out_rx.recv().await {
            if write_half.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if write_half.write_all(b"\n").await.is_err() {
                break;
            }
        }
    });

    // Forward engine events to this client.
    let mut events = engine.subscribe();
    let event_tx = out_tx.clone();
    let event_forwarder = tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    let env = EventEnvelope {
                        protocol_version: PROTOCOL_VERSION,
                        event,
                    };
                    if let Ok(line) = serde_json::to_string(&env) {
                        if event_tx.send(line).is_err() {
                            break;
                        }
                    }
                }
                // Lagged: keep going; missing a progress tick is acceptable.
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    // Read requests line-by-line and dispatch.
    let mut lines = BufReader::new(read_half).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let response_env = match serde_json::from_str::<RequestEnvelope>(&line) {
            Ok(env) => {
                if env.protocol_version != PROTOCOL_VERSION {
                    ResponseEnvelope {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: env.request_id,
                        response: Response::Error {
                            message: format!(
                                "protocol version mismatch: engine v{PROTOCOL_VERSION}, client v{}",
                                env.protocol_version
                            ),
                        },
                    }
                } else {
                    let response = engine.dispatch(env.request).await;
                    ResponseEnvelope {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: env.request_id,
                        response,
                    }
                }
            }
            Err(e) => ResponseEnvelope {
                protocol_version: PROTOCOL_VERSION,
                request_id: RequestId(String::new()),
                response: Response::Error {
                    message: format!("malformed request: {e}"),
                },
            },
        };
        if let Ok(text) = serde_json::to_string(&response_env) {
            if out_tx.send(text).is_err() {
                break;
            }
        }
    }

    // Client disconnected: tear down the helper tasks.
    drop(out_tx);
    event_forwarder.abort();
    let _ = writer.await;
    Ok(())
}
