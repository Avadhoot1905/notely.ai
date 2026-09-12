//! Persistence. All database/filesystem detail is confined here.
//!
//! Local-first: data lives on the user's machine, in an embedded SQLite database (no external
//! server). The rest of the engine — and, through IPC, Flutter — works with `domain` types and the
//! [`Store`] trait, never with SQL or file paths. See `docs/storage.md`.

pub mod database;
pub mod repositories;

pub use database::SqliteStore;
pub use repositories::{StorageError, Store};
