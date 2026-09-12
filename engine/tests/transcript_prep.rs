//! Deterministic transcript preparation over the committed evaluation fixture:
//! the same input must always normalize + chunk to the same result, and the raw ASR output is
//! preserved unchanged.

use notely_engine::config::ChunkingConfig;
use notely_engine::domain::Transcript;
use notely_engine::preprocess::prepare;

fn load_fixture() -> Transcript {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../data/fixtures/transcripts/weekly-eng-sync.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture exists"))
        .expect("fixture parses")
}

#[test]
fn preparation_is_deterministic_and_preserves_raw() {
    let raw = load_fixture();
    let a = prepare(&raw, &ChunkingConfig::default());
    let b = prepare(&raw, &ChunkingConfig::default());

    assert_eq!(a.chunks, b.chunks, "same input → identical chunks");
    assert!(!a.chunks.is_empty());
    assert_eq!(a.raw, raw, "raw transcript preserved unchanged");

    // Chunk ranges are contiguous and cover every normalized segment.
    assert_eq!(a.chunks.first().unwrap().segment_start, 0);
    for w in a.chunks.windows(2) {
        assert_eq!(w[0].segment_end, w[1].segment_start);
    }
    assert_eq!(
        a.chunks.last().unwrap().segment_end,
        a.normalized.segments.len()
    );
}

#[test]
fn small_max_chars_splits_the_fixture_into_multiple_ordered_chunks() {
    let raw = load_fixture();
    let cfg = ChunkingConfig {
        max_chars: 120,
        context_chars: 40,
    };
    let prepared = prepare(&raw, &cfg);
    assert!(
        prepared.chunks.len() > 1,
        "small budget should produce several chunks"
    );
    // Chunk ids are stable and ordered.
    for (i, c) in prepared.chunks.iter().enumerate() {
        assert_eq!(c.id, format!("chunk-{i}"));
        assert_eq!(c.index, i);
    }
    // Interior chunks carry neighbor context.
    assert!(prepared.chunks[1].preceding_context.is_some());
}
