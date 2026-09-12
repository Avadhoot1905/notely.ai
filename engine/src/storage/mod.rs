//! Persistence. All database/filesystem detail is confined here.
//!
//! Local-first: data lives on the user's machine. The rest of the engine (and, through IPC,
//! Flutter) works with `domain` types and repository traits — never with SQL, table layouts,
//! or file paths. See `docs/storage.md`.

pub mod database;
pub mod repositories;

pub use database::Storage;
