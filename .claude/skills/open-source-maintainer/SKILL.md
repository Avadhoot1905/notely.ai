---
name: open-source-maintainer
description: Load when making changes with external contributors in mind, triaging issues/PRs, or shaping contribution flow. Notely is open-source and local-first — changes must be understandable and reproducible by contributors, not just the original author.
---

# open-source-maintainer

## Context
Notely is an **open-source, local-first** project (`docs/product.md`). Contributors run it on their
own machines with their own models. Optimize for their ability to understand, reproduce, and extend —
not just for shipping a fix.

## Repo touchpoints
- Issue/PR templates: `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.md`,
  `.github/pull_request_template.md`. Contribution flow runs through CI (`ci.yml`) which every PR must pass.
- Onboarding: `docs/development.md` (prereqs, config table, scripts), `scripts/bootstrap.sh`,
  `README.md`. `docs/decisions.md` explains *why* — point contributors there before they "fix" a
  deliberate choice.

## Make changes contributor-friendly
- **Reproducibility:** use fixtures (`data/fixtures/`) so behavior is checkable without a specific
  model; keep live-model paths `#[ignore]`d. State the exact commands to reproduce.
- **PR scope:** one coherent change (minimal-change); a reviewer should hold it in their head. Split
  refactors from fixes.
- **Explain intent:** the repo's file-level doc comments and the decisions log are the culture —
  match it. A new seam gets a doc comment; a new decision gets a `D-00xx` entry.
- **Breaking changes:** call them out explicitly, bump `PROTOCOL_VERSION` for IPC, provide migrations,
  and update docs (documentation-sync, backwards-compatibility). Don't strand existing vaults/DBs.
- **Honesty over polish:** the codebase openly marks gaps ("not implemented", "compile-gated only",
  "generic meeting"). Keep that honesty in code, docs, and the capability matrix — never overclaim.

## Triage
- **Bugs:** ask for OS + version + arch + runtime (Ollama/ASR) + repro; classify by subsystem
  (repo-navigation); many "AI is wrong" reports are model-quality, not code bugs — distinguish them.
- **Good first issues:** deterministic Rust units (chunking/rendering/validation), Dart widget/state
  tests, docs — areas testable without a live model.
- **Maintainer burden:** prefer configuration over new abstractions/deps (dependency-audit); each new
  seam is future maintenance.

## Related skills
documentation-sync · code-review · testing · backwards-compatibility · dependency-audit · compatibility-matrix
