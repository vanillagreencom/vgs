---
applyTo: "third_party/review-gate/**"
---

This tree is the review-gate engine, vendored BYTE-PINNED from
vanillagreencom/vstack — the bytes reviewed upstream are the bytes that run.

- Real defects here are fixed upstream first, then re-vendored; flag them,
  but do not ask for local edits to these files.
- Do not propose local restructuring (splitting files, style or naming
  changes, line-count limits, test reorganization): any local delta forks
  the pinned surface, which the repo's vendor check exists to prevent.
- The engine's behavioral test suites run upstream on every engine change;
  this repo's committed control is byte-identity plus the vendored offline
  selftest in CI. Do not ask for duplicate local suites.
- Cross-repo sync timing (an upstream fix not yet re-vendored here) is a
  coordination note, never a merge blocker.
