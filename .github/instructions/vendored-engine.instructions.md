---
applyTo: "third_party/review-gate/**"
---

This tree is the review-gate engine, vendored BYTE-PINNED from
vanillagreencom/vstack — the bytes reviewed upstream are the bytes that run.

- Real defects here are fixed upstream first, then re-vendored; flag them,
  but do not ask for local edits to these files.
- Do not propose local restructuring (splitting files, style or naming
  changes, line-count limits, test reorganization): any local delta forks this
  tree from upstream, and a fork of the engine that decides merges is not a
  thing to carry.
- **A local edit here PERSISTS.** `kendex refresh` writes
  `.agents/skills/review-gate/`, not this tree, and the vendor checker that
  kept the two in step went on 2026-08-26. So an edit survives, in the copy
  `review-gate-writer.yml` execs. Still fix it upstream with `kendex report`
  and copy the re-render across deliberately (VGS-223).
- The engine's behavioral test suites run upstream on every engine change, and
  since 2026-08-26 this repo runs none of them and diffs nothing against the
  upstream copy — the vendor-diff checks retired with them. Do not ask for
  local suites over this tree, duplicate or otherwise.
- Cross-repo sync timing (an upstream fix not yet re-vendored here) is a
  coordination note, never a merge blocker.
