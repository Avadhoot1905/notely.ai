//! Database/handle lifecycle. The concrete backend (SQLite is the likely v0 choice, possibly
//! alongside plain files for large artifacts) is an implementation detail hidden behind this
//! type and the repository traits.

/// Owns the storage connection(s). A real backend handle will live here.
#[derive(Default)]
pub struct Storage;

impl Storage {
    /// Open an ephemeral store — used by the scaffold and tests until a backend is wired.
    ///
    /// TODO(v0): add `open(path)` for the on-disk local database.
    pub fn open_in_memory() -> anyhow::Result<Self> {
        Ok(Storage)
    }
}
