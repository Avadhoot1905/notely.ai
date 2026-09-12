//! IPC boundary between the Flutter desktop app and the Rust engine.
//!
//! IPC is the primary (and for v0, only) backend boundary. Everything the app can ask the engine
//! to do flows through a small, versioned, serializable protocol so the transport can change later
//! without rewriting the pipeline.
//!
//! ```text
//! Flutter ──request──▶ IPC ──▶ Engine
//! Flutter ◀──event──── IPC ◀── Engine
//! ```
//!
//! Layout:
//!   - [`protocol`] — request/response types, request ids, versioning.
//!   - [`events`]   — asynchronous progress/lifecycle events.
//!   - [`server`]   — transport-isolated server that routes requests into the [`crate::Engine`].

pub mod events;
pub mod protocol;
pub mod server;

pub use protocol::PROTOCOL_VERSION;
pub use server::Server;
