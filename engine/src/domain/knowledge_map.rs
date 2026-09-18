//! The Knowledge Space model — a semantic-topographic view of the vault.
//!
//! This is deliberately *not* a node-link graph. It describes the user's knowledge as a landscape:
//! [`Concept`]s are peaks whose height ([`Concept::mass`]) is knowledge density, grouped into
//! continuous [`Region`]s (conceptual domains), positioned so that semantic distance ≈ spatial
//! distance. The renderer turns this into terrain + typography; nothing here dictates pixels.
//!
//! Like the rest of `domain`, these types depend on nothing but `serde`. Every coordinate is
//! normalized to `[0.0, 1.0]` so the client can lay it out at any size, and every concept traces
//! back to real, citable evidence via [`Concept::term`] (searchable) — the landscape is derived
//! from indexed source material, never fabricated.

use serde::{Deserialize, Serialize};

/// One conceptual region ("hill"/domain) of the knowledge landscape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Region {
    /// Stable index of this region within the map.
    pub id: usize,
    /// Typographic label — the most prominent concept in the region (the peak's name).
    pub label: String,
    /// Region centroid, normalized to `[0,1]`.
    pub x: f64,
    pub y: f64,
    /// Approximate radius (normalized) — the region's footprint; scales with mass.
    pub radius: f64,
    /// Total knowledge density of the region (sum of its concept masses).
    pub mass: f64,
    /// How many concepts fall in this region.
    pub concept_count: usize,
    /// Distinct evidence documents contributing to this region.
    pub doc_count: usize,
    /// Prominence rank, `0` = most prominent. Drives semantic zoom (fewer, bigger regions first).
    pub rank: usize,
    /// Which source kinds feed this region (e.g. `["markdown", "slack"]`) — the cross-source story.
    pub sources: Vec<String>,
}

/// A single concept — a peak in the landscape. Its `term` is a real, searchable token so the UI can
/// drill straight to the underlying evidence.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Concept {
    /// The region this concept belongs to ([`Region::id`]).
    pub region_id: usize,
    /// The concept label — a salient term or phrase drawn from the corpus.
    pub term: String,
    /// Position, normalized to `[0,1]`. Bigger concepts sit nearer their region's centre (the peak).
    pub x: f64,
    pub y: f64,
    /// Knowledge density (tf-idf mass) — the peak height / label weight.
    pub mass: f64,
    /// Distinct documents this concept appears in.
    pub doc_count: usize,
    /// Global prominence rank, `0` = most prominent. Drives semantic zoom (labels appear in tiers).
    pub rank: usize,
    /// Which source kinds this concept draws from (e.g. `["markdown", "teams"]`).
    pub sources: Vec<String>,
}

/// Corpus-level facts about how the map was derived — surfaced so the UI never implies more
/// coverage than exists (small/sparse vaults look small, and truncation is reported).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct MapStats {
    /// Distinct notes considered.
    pub note_count: usize,
    /// Concepts kept in the map.
    pub concept_count: usize,
    /// Regions formed.
    pub region_count: usize,
    /// True when the corpus exceeded the analysis cap and was sampled (honesty about coverage).
    pub truncated: bool,
}

/// The full derived Knowledge Space: regions (domains) and the concepts (peaks) within them.
///
/// Empty `regions`/`concepts` is a valid, expected result for an empty or nearly-empty vault — the
/// client renders a calm empty state rather than inventing structure.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct KnowledgeMap {
    pub regions: Vec<Region>,
    pub concepts: Vec<Concept>,
    pub stats: MapStats,
}
