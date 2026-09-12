// Mock markdown note bodies keyed by note id.
//
// Stand-in for note content the Rust engine will eventually read from disk. The editor holds
// live edits in memory (see EditorController); these are just the initial contents.

/// Stable ids referenced by the file tree and the editor.
abstract final class NoteIds {
  static const teamSync = 'team-sync';
  static const productReview = 'product-review';
  static const q3Planning = 'q3-planning';
  static const architecture = 'architecture';
  static const roadmap = 'roadmap';
  static const qshieldNotes = 'qshield-notes';
  static const ideas = 'ideas';
  static const todo = 'todo';
}

/// Initial markdown bodies for the seeded stash.
const Map<String, String> mockNotes = {
  NoteIds.teamSync: '''# Team Sync

**Date:** September 12, 2026

## Summary

We discussed the upcoming release and the remaining
deployment work.

## Decisions

- Release moved to Friday.
- Staging must be validated before deployment.

## Action Items

- [ ] Update deployment pipeline — Avadhoot
- [ ] Complete staging checklist — Rahul
- [ ] Document rollback procedure — Avadhoot

## Notes

The release process should remain reversible.
''',
  NoteIds.productReview: '''# Product Review

**Date:** September 10, 2026

## Agenda

1. Onboarding funnel metrics
2. Editor performance regressions
3. Q4 roadmap candidates

## Highlights

- Activation up **8%** after the new empty state.
- Large notes (>5k lines) still stutter on scroll.

## Follow-ups

- [ ] Profile the editor scroll path — Priya
- [ ] Draft Q4 candidate list — Avadhoot
''',
  NoteIds.q3Planning: '''# Q3 Planning

**Date:** September 3, 2026

## Themes

- Local-first reliability
- Meeting capture quality
- Editor polish

## Commitments

- Ship the Stash picker.
- Ship live transcript panel.
- Reduce cold-start time below 800ms.
''',
  NoteIds.architecture: '''# Architecture

Notely is a **local-first** desktop app.

```text
Flutter UI  ──IPC──▶  Rust engine
```

## Principles

- UI owns presentation + interaction only.
- The engine owns media, ASR, analysis, storage.
- The two sides share a versioned protocol.

## Layers

1. Workspace shell (three-region layout)
2. Feature controllers (stash, explorer, editor, listening)
3. Mock services (to be replaced by the IPC client)
''',
  NoteIds.roadmap: '''# Roadmap

## Now

- [x] Stash picker
- [x] Explorer + editor shell
- [ ] Real IPC client

## Next

- [ ] Meeting summarization
- [ ] Full-text search across the stash
''',
  NoteIds.qshieldNotes: '''# QShield — Notes

Scratch notes for the QShield integration.

- Threat model draft lives in the shared drive.
- Need to confirm the audit log format.
''',
  NoteIds.ideas: '''# Ideas

- Quick-capture hotkey that drops into today's daily note.
- Inline speaker labels you can rename after a meeting.
- "Turn transcript into action items" command.
''',
  NoteIds.todo: '''# TODO

- [ ] Review the deployment checklist
- [ ] Reply to Priya about staging
- [x] Send the release notes draft
''',
};
