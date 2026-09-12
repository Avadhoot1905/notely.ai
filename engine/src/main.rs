//! Notely engine binary — a thin entry point over the library's [`notely_engine::run`].
//!
//! All logic lives in the library crate (`src/lib.rs` and its modules) so it can be unit- and
//! integration-tested. This binary just starts the async runtime and runs the engine.

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(notely_engine::run())
}
