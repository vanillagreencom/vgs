---
applyTo: "third_party/review-gate/**"
---

This tree is the review-gate engine, vendored BYTE-PINNED from
vanillagreencom/vstack — the bytes reviewed upstream are the bytes that run.

- Real defects here are fixed upstream first, then re-vendored; flag them,
  but do not ask for local edits to these files.
- Do not propose local restructuring (splitting files, style or naming
  changes, line-count limits, test reorganization): any local delta forks the
  vendored surface, and the next `kendex refresh` overwrites it wholesale, so
  the finding reads as closed while the bytes go back.
- The engine's behavioral test suites run upstream on every engine change, and
  since 2026-08-26 this repo runs none of them and diffs nothing against the
  upstream copy — the vendor-diff checks retired with them. Do not ask for
  local suites over this tree, duplicate or otherwise.
- Cross-repo sync timing (an upstream fix not yet re-vendored here) is a
  coordination note, never a merge blocker.
