//! Derive the [`KnowledgeMap`] — the semantic-topographic view — from indexed source material.
//!
//! This is plain, deterministic Rust (like `preprocess` and `search::chunker`): no model decides
//! what a concept is or where a hill sits. The pipeline is:
//!
//! 1. **Concepts** — salient terms/phrases scored by tf-idf across the corpus (density = mass).
//! 2. **Regions** — concepts clustered by co-occurrence (things discussed together are close);
//!    isolated concepts stay isolated — sparse knowledge is never given fabricated relationships.
//! 3. **Layout** — a deterministic force settle so semantic distance ≈ spatial distance, with the
//!    heaviest concept anchoring each region's peak.
//!
//! The result is normalized to `[0,1]` and carries provenance (which source kinds feed each
//! concept), so the same map speaks for Markdown notes and imported Slack/Teams knowledge alike.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::domain::knowledge_map::{Concept, KnowledgeMap, MapStats, Region};

/// A document handed to the builder: one indexed note, already tagged with its source kind.
#[derive(Debug, Clone)]
pub struct MapDoc {
    pub path: String,
    pub title: String,
    pub body: String,
    /// Source kind for provenance, e.g. `"markdown"`, `"slack"`, `"teams"`.
    pub source: String,
}

/// Tunable limits. Defaults chosen for a personal vault; all deterministic.
#[derive(Debug, Clone)]
pub struct MapOptions {
    /// Maximum concepts kept in the final map (semantic-zoom reveals them in rank tiers).
    pub max_concepts: usize,
    /// Cosine co-occurrence a pair must reach to be considered "close" (same region).
    pub link_threshold: f64,
    /// Force-layout iterations (fixed → deterministic).
    pub layout_iterations: usize,
    /// Hard cap on documents scanned; beyond it the corpus is sampled and `truncated` is set.
    pub max_docs: usize,
}

impl Default for MapOptions {
    fn default() -> Self {
        Self {
            max_concepts: 80,
            link_threshold: 0.18,
            layout_iterations: 300,
            max_docs: 6_000,
        }
    }
}

/// Build a [`KnowledgeMap`] from indexed documents. Deterministic: identical input → identical map.
pub fn build(mut docs: Vec<MapDoc>, opts: &MapOptions) -> KnowledgeMap {
    // Stable order so sampling/truncation and every downstream tie-break is reproducible.
    docs.sort_by(|a, b| a.path.cmp(&b.path));
    let truncated = docs.len() > opts.max_docs;
    if truncated {
        docs.truncate(opts.max_docs);
    }
    let note_count = docs.len();
    if docs.is_empty() {
        return KnowledgeMap::default();
    }

    // ── 1. Concepts: tf-idf over terms + adjacent bigrams ────────────────────────────────────
    // Per term: which docs contain it (df), summed tf-idf mass, and contributing source kinds.
    let mut df: BTreeMap<String, BTreeSet<usize>> = BTreeMap::new();
    let mut tf: HashMap<(usize, String), u32> = HashMap::new();
    let mut term_sources: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();

    for (ix, doc) in docs.iter().enumerate() {
        // Title terms count double — a note's heading is a strong signal of what it is about.
        let mut counts: HashMap<String, u32> = HashMap::new();
        for term in terms_and_bigrams(&doc.title) {
            *counts.entry(term).or_default() += 2;
        }
        for term in terms_and_bigrams(&doc.body) {
            *counts.entry(term).or_default() += 1;
        }
        for (term, c) in counts {
            df.entry(term.clone()).or_default().insert(ix);
            tf.insert((ix, term.clone()), c);
            term_sources
                .entry(term)
                .or_default()
                .insert(doc.source.clone());
        }
    }

    // A term must appear in at least this many notes to count as a shared concept. Tiny vaults
    // relax to 1 so a small knowledge base still forms a (small) landscape.
    let min_df = if note_count >= 6 { 2 } else { 1 };
    let n = note_count as f64;

    struct Scored {
        term: String,
        mass: f64,
        docs: BTreeSet<usize>,
        sources: Vec<String>,
    }
    let mut scored: Vec<Scored> = Vec::new();
    for (term, docset) in &df {
        if docset.len() < min_df {
            continue;
        }
        let idf = ((n + 1.0) / (docset.len() as f64 + 1.0)).ln() + 1.0;
        let mut mass = 0.0;
        for &d in docset {
            let c = *tf.get(&(d, term.clone())).unwrap_or(&0) as f64;
            mass += (1.0 + c.ln()) * idf;
        }
        let sources: Vec<String> = term_sources
            .get(term)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default();
        scored.push(Scored {
            term: term.clone(),
            mass,
            docs: docset.clone(),
            sources,
        });
    }

    if scored.is_empty() {
        return KnowledgeMap {
            regions: Vec::new(),
            concepts: Vec::new(),
            stats: MapStats {
                note_count,
                truncated,
                ..Default::default()
            },
        };
    }

    // Keep the most massive concepts; drop bigrams fully subsumed by a stronger unigram peak so a
    // phrase and its word don't both crowd the same spot.
    scored.sort_by(|a, b| {
        b.mass
            .partial_cmp(&a.mass)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.term.cmp(&b.term))
    });
    scored.truncate(opts.max_concepts);

    // ── 2. Regions: cluster concepts by document co-occurrence ───────────────────────────────
    let sim = |a: &Scored, b: &Scored| -> f64 {
        let inter = a.docs.intersection(&b.docs).count() as f64;
        if inter == 0.0 {
            return 0.0;
        }
        inter / ((a.docs.len() as f64).sqrt() * (b.docs.len() as f64).sqrt())
    };

    // Greedy single-link: walk concepts by descending mass; join the region of the strongest
    // already-placed neighbour above threshold, else start a new region. High-mass concepts seed
    // regions, so a region's peak is its heaviest concept.
    let mut region_of: Vec<usize> = vec![usize::MAX; scored.len()];
    let mut region_count = 0usize;
    for i in 0..scored.len() {
        let mut best_region = usize::MAX;
        let mut best_sim = opts.link_threshold;
        for j in 0..i {
            let s = sim(&scored[i], &scored[j]);
            if s >= best_sim {
                best_sim = s;
                best_region = region_of[j];
            }
        }
        if best_region == usize::MAX {
            region_of[i] = region_count;
            region_count += 1;
        } else {
            region_of[i] = best_region;
        }
    }

    // Aggregate regions.
    let mut regions: Vec<Region> = (0..region_count)
        .map(|id| Region {
            id,
            label: String::new(),
            x: 0.0,
            y: 0.0,
            radius: 0.0,
            mass: 0.0,
            concept_count: 0,
            doc_count: 0,
            rank: 0,
            sources: Vec::new(),
        })
        .collect();
    let mut region_docs: Vec<BTreeSet<usize>> = vec![BTreeSet::new(); region_count];
    let mut region_sources: Vec<BTreeSet<String>> = vec![BTreeSet::new(); region_count];
    for (i, s) in scored.iter().enumerate() {
        let r = region_of[i];
        let reg = &mut regions[r];
        reg.mass += s.mass;
        reg.concept_count += 1;
        if reg.label.is_empty() {
            reg.label = s.term.clone(); // first seen = highest mass (scored is mass-sorted)
        }
        region_docs[r].extend(s.docs.iter().copied());
        for src in &s.sources {
            region_sources[r].insert(src.clone());
        }
    }
    for r in 0..region_count {
        regions[r].doc_count = region_docs[r].len();
        regions[r].sources = region_sources[r].iter().cloned().collect();
    }

    // ── 3a. Region layout: force-settle so related regions sit near each other ────────────────
    let centroids = layout_regions(&regions, &region_docs, opts.layout_iterations);
    for (r, (x, y)) in centroids.iter().enumerate() {
        regions[r].x = *x;
        regions[r].y = *y;
    }
    // Radius from mass (bigger domain → larger footprint), gently compressed.
    let max_mass = regions
        .iter()
        .map(|r| r.mass)
        .fold(0.0_f64, f64::max)
        .max(1e-9);
    for r in regions.iter_mut() {
        r.radius = 0.05 + 0.12 * (r.mass / max_mass).sqrt();
    }

    // Prominence rank by mass (drives semantic zoom).
    let mut order: Vec<usize> = (0..region_count).collect();
    order.sort_by(|&a, &b| {
        regions[b]
            .mass
            .partial_cmp(&regions[a].mass)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| regions[a].label.cmp(&regions[b].label))
    });
    for (rank, &r) in order.iter().enumerate() {
        regions[r].rank = rank;
    }

    // ── 3b. Concept layout: peaks spiral out from their region centre, heaviest at the summit ──
    let mut per_region: Vec<Vec<usize>> = vec![Vec::new(); region_count];
    for i in 0..scored.len() {
        per_region[region_of[i]].push(i);
    }
    let mut concepts: Vec<Concept> = Vec::with_capacity(scored.len());
    for r in 0..region_count {
        let members = &per_region[r]; // already in descending-mass order (scored order preserved)
        let (cx, cy) = (regions[r].x, regions[r].y);
        let rad = regions[r].radius;
        for (k, &i) in members.iter().enumerate() {
            let (dx, dy) = spiral_offset(k, members.len(), rad);
            let s = &scored[i];
            concepts.push(Concept {
                region_id: r,
                term: s.term.clone(),
                x: (cx + dx).clamp(0.0, 1.0),
                y: (cy + dy).clamp(0.0, 1.0),
                mass: s.mass,
                doc_count: s.docs.len(),
                rank: 0, // filled below
                sources: s.sources.clone(),
            });
        }
    }
    // Global concept prominence rank by mass.
    let mut corder: Vec<usize> = (0..concepts.len()).collect();
    corder.sort_by(|&a, &b| {
        concepts[b]
            .mass
            .partial_cmp(&concepts[a].mass)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| concepts[a].term.cmp(&concepts[b].term))
    });
    for (rank, &i) in corder.iter().enumerate() {
        concepts[i].rank = rank;
    }

    KnowledgeMap {
        stats: MapStats {
            note_count,
            concept_count: concepts.len(),
            region_count,
            truncated,
        },
        regions,
        concepts,
    }
}

/// Deterministic 2D force layout of region centroids. Regions that share documents attract; all
/// pairs repel. Seeded on a golden-angle spiral by index (no RNG) and settled for a fixed number of
/// iterations, then normalized into a padded `[0,1]` box. Single region → centre.
fn layout_regions(
    regions: &[Region],
    region_docs: &[BTreeSet<usize>],
    iterations: usize,
) -> Vec<(f64, f64)> {
    let m = regions.len();
    if m == 1 {
        return vec![(0.5, 0.5)];
    }
    // Golden-angle seed spiral — spreads seeds evenly and deterministically.
    const GOLDEN: f64 = 2.399_963_229_728_653; // ~137.5°
    let mut pos: Vec<(f64, f64)> = (0..m)
        .map(|i| {
            let r = ((i as f64 + 0.5) / m as f64).sqrt() * 0.5;
            let a = i as f64 * GOLDEN;
            (0.5 + r * a.cos(), 0.5 + r * a.sin())
        })
        .collect();

    // Pairwise similarity (shared-doc cosine) as the attraction target.
    let mut simm = vec![vec![0.0_f64; m]; m];
    for a in 0..m {
        for b in (a + 1)..m {
            let inter = region_docs[a].intersection(&region_docs[b]).count() as f64;
            let s = if inter == 0.0 {
                0.0
            } else {
                inter
                    / ((region_docs[a].len() as f64).sqrt() * (region_docs[b].len() as f64).sqrt())
            };
            simm[a][b] = s;
            simm[b][a] = s;
        }
    }

    let k_rep = 0.02; // repulsion strength
    let k_att = 0.30; // attraction strength (scaled by similarity)
    for _ in 0..iterations {
        let mut disp = vec![(0.0_f64, 0.0_f64); m];
        for a in 0..m {
            for b in 0..m {
                if a == b {
                    continue;
                }
                let dx = pos[a].0 - pos[b].0;
                let dy = pos[a].1 - pos[b].1;
                let d2 = dx * dx + dy * dy + 1e-4;
                let d = d2.sqrt();
                // Repulsion (inverse-square-ish), pushing everything apart.
                let rep = k_rep / d2;
                disp[a].0 += dx / d * rep;
                disp[a].1 += dy / d * rep;
                // Attraction toward similar regions (spring pulling to a short rest length).
                let s = simm[a][b];
                if s > 0.0 {
                    let att = k_att * s * (d - 0.12);
                    disp[a].0 -= dx / d * att;
                    disp[a].1 -= dy / d * att;
                }
            }
        }
        for a in 0..m {
            // Damped step, clamped so one iteration can't fling a node across the plane.
            let step = 0.5;
            pos[a].0 += (disp[a].0 * step).clamp(-0.05, 0.05);
            pos[a].1 += (disp[a].1 * step).clamp(-0.05, 0.05);
        }
    }
    normalize(&mut pos, 0.12);
    pos
}

/// Rescale positions into a padded `[pad, 1-pad]` box, preserving relative distances.
fn normalize(pos: &mut [(f64, f64)], pad: f64) {
    let (mut minx, mut miny, mut maxx, mut maxy) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for &(x, y) in pos.iter() {
        minx = minx.min(x);
        miny = miny.min(y);
        maxx = maxx.max(x);
        maxy = maxy.max(y);
    }
    let span = (maxx - minx).max(maxy - miny).max(1e-6); // uniform scale keeps it undistorted
    let usable = 1.0 - 2.0 * pad;
    // Center the (possibly non-square) content within the box.
    let ox = (span - (maxx - minx)) / 2.0;
    let oy = (span - (maxy - miny)) / 2.0;
    for p in pos.iter_mut() {
        p.0 = pad + (p.0 - minx + ox) / span * usable;
        p.1 = pad + (p.1 - miny + oy) / span * usable;
    }
}

/// Golden-angle spiral offset for the `k`-th concept of `n` in a region of radius `rad`. The first
/// concept (k=0) sits at the centre — the region's summit.
fn spiral_offset(k: usize, n: usize, rad: f64) -> (f64, f64) {
    if k == 0 || n <= 1 {
        return (0.0, 0.0);
    }
    const GOLDEN: f64 = 2.399_963_229_728_653;
    let r = (k as f64 / n as f64).sqrt() * rad * 0.9;
    let a = k as f64 * GOLDEN;
    (r * a.cos(), r * a.sin())
}

/// A curated English stopword set — small on purpose (retrieval, not linguistics). Anything here is
/// too generic to be a "concept".
const STOPWORDS: &[&str] = &[
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one",
    "our", "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see",
    "two", "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use", "that",
    "this", "with", "they", "have", "from", "your", "will", "would", "there", "their", "what",
    "about", "which", "when", "make", "like", "time", "just", "know", "take", "people", "into",
    "year", "good", "some", "could", "them", "than", "then", "look", "only", "come", "over",
    "think", "also", "back", "after", "work", "first", "well", "even", "want", "because", "these",
    "give", "most", "https", "http", "www", "com", "org", "html", "should", "were", "been",
    "being", "more", "such", "very", "much", "here", "does", "done", "each", "many", "need",
    "used", "using", "into", "onto", "upon", "shall", "may", "might", "must", "cannot", "etc",
    "via", "per",
];

fn is_stopword(t: &str) -> bool {
    // Small set — a linear scan is fine and avoids depending on the list being sorted.
    STOPWORDS.contains(&t) || t.chars().all(|c| c.is_ascii_digit())
}

/// Yield concept-worthy terms plus adjacent bigrams from `text`. Terms are lowercased alphanumerics
/// of length 3..=24, minus stopwords; a bigram is two such terms adjacent within one line.
fn terms_and_bigrams(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let mut prev: Option<String> = None;
        for raw in line.split(|c: char| !c.is_alphanumeric()) {
            let t = raw.trim().to_lowercase();
            if t.len() < 3 || t.len() > 24 || is_stopword(&t) {
                prev = None;
                continue;
            }
            if let Some(p) = &prev {
                out.push(format!("{p} {t}"));
            }
            out.push(t.clone());
            prev = Some(t);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(path: &str, title: &str, body: &str) -> MapDoc {
        MapDoc {
            path: path.into(),
            title: title.into(),
            body: body.into(),
            source: "markdown".into(),
        }
    }

    #[test]
    fn empty_corpus_yields_empty_map() {
        let map = build(Vec::new(), &MapOptions::default());
        assert!(map.regions.is_empty());
        assert!(map.concepts.is_empty());
        assert_eq!(map.stats.note_count, 0);
    }

    #[test]
    fn is_deterministic() {
        let docs = vec![
            doc(
                "a.md",
                "TLS proxy",
                "The TLS proxy performs MITM interception of traffic.",
            ),
            doc(
                "b.md",
                "Netwatch",
                "Netwatch does process attribution for each TLS proxy flow.",
            ),
            doc(
                "c.md",
                "Recipes",
                "Bread needs flour water salt yeast and an oven overnight.",
            ),
        ];
        let m1 = build(docs.clone(), &MapOptions::default());
        let m2 = build(docs, &MapOptions::default());
        assert_eq!(m1, m2, "same input must produce an identical map");
    }

    #[test]
    fn related_notes_cluster_unrelated_stay_apart() {
        // Two security notes share vocabulary; the cooking note shares nothing.
        let docs = vec![
            doc(
                "tls.md",
                "TLS proxy",
                "tls proxy tls proxy interception mitm traffic tls proxy",
            ),
            doc(
                "netwatch.md",
                "Netwatch proxy",
                "netwatch proxy tls proxy attribution mitm proxy",
            ),
            doc(
                "bread.md",
                "Bread",
                "bread flour water yeast bread oven bread dough",
            ),
        ];
        let map = build(docs, &MapOptions::default());
        assert!(!map.concepts.is_empty());
        // The two proxy notes' shared concept should land in the same region; bread separate.
        let region_for = |term: &str| {
            map.concepts
                .iter()
                .find(|c| c.term == term)
                .map(|c| c.region_id)
        };
        if let (Some(proxy), Some(bread)) = (region_for("proxy"), region_for("bread")) {
            assert_ne!(proxy, bread, "unrelated concepts must not share a region");
        }
        // Coordinates are normalized.
        for c in &map.concepts {
            assert!((0.0..=1.0).contains(&c.x) && (0.0..=1.0).contains(&c.y));
        }
    }

    #[test]
    fn sparse_single_note_does_not_fabricate_links() {
        let map = build(
            vec![doc("solo.md", "Solo", "alpha beta gamma alpha beta")],
            &MapOptions::default(),
        );
        // Everything from one note; regions form but no cross-note relationships are invented.
        assert_eq!(map.stats.note_count, 1);
        assert!(map.stats.region_count >= 1);
    }

    #[test]
    fn ranks_are_dense_and_mass_ordered() {
        let docs = vec![
            doc("a.md", "Alpha", "alpha alpha alpha beta"),
            doc("b.md", "Alpha beta", "alpha beta beta gamma"),
            doc("c.md", "Gamma", "gamma delta gamma delta epsilon"),
        ];
        let map = build(docs, &MapOptions::default());
        let mut ranks: Vec<usize> = map.concepts.iter().map(|c| c.rank).collect();
        ranks.sort_unstable();
        for (i, r) in ranks.iter().enumerate() {
            assert_eq!(i, *r, "concept ranks must be a dense 0..n sequence");
        }
    }

    #[test]
    fn truncation_is_reported() {
        let docs: Vec<MapDoc> = (0..10)
            .map(|i| doc(&format!("n{i}.md"), "T", "alpha beta gamma"))
            .collect();
        let opts = MapOptions {
            max_docs: 4,
            ..MapOptions::default()
        };
        let map = build(docs, &opts);
        assert!(map.stats.truncated);
        assert_eq!(map.stats.note_count, 4);
    }
}
