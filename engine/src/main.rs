//! Notely engine — the single local backend for the Notely desktop app.
//!
//! The engine is the ONE Rust process/package in this repository. It is internally
//! modular (see the modules below) but is intentionally not split into multiple crates
//! for v0. Flutter talks to it exclusively over the IPC boundary in [`ipc`].
//!
//! Startup responsibilities (see [`run`]):
//!   1. Initialize configuration
//!   2. Initialize storage
//!   3. Initialize model/runtime dependencies
//!   4. Start the IPC server
//!   5. Accept commands from Flutter, run jobs, emit events, persist results.

// v0 is a scaffold: many modules define the intended shape before they are wired together,
// so unused code and not-yet-consumed re-exports are expected. Remove these as the
// pipeline is implemented.
#![allow(dead_code, unused_imports)]

mod ai;
mod asr;
mod domain;
mod ipc;
mod llm;
mod media;
mod pipeline;
mod renderer;
mod storage;

use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    run().await
}

/// Boot the engine and block serving IPC requests until shutdown.
///
/// TODO(v0): wire the real initialization sequence. For now this proves the
/// module tree compiles and documents the intended lifecycle.
async fn run() -> Result<()> {
    tracing::info!(
        "notely-engine starting (protocol v{})",
        ipc::PROTOCOL_VERSION
    );

    // 1. Configuration — TODO: load from user config dir / env.
    // 2. Storage — TODO: open the local database.
    let _storage = storage::Storage::open_in_memory()?;
    // 3. Runtime deps — TODO: probe LLM runtime (e.g. Ollama) and ASR availability.
    // 4. IPC server — TODO: bind the transport and serve.
    let _server = ipc::Server::new();

    tracing::info!("notely-engine initialized (scaffold only — no transport bound yet)");
    Ok(())
}
