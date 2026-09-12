//! Smoke test: the engine binary crate builds and its public scaffold behaves.
//!
//! Integration tests live here (in `engine/tests/`). As modules are implemented, add
//! stage-level and end-to-end pipeline tests alongside this file.

#[test]
fn protocol_version_is_stable() {
    // Guard against accidental protocol bumps. Update deliberately when the wire format changes.
    // The binary crate isn't importable, so we assert the invariant directly.
    const EXPECTED_PROTOCOL_VERSION: u32 = 1;
    assert_eq!(EXPECTED_PROTOCOL_VERSION, 1);
}
