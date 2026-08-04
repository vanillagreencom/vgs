# Architectural Decision Log

Records the significant path choices VGS has made, so a later reader can see what
was chosen, why, and what would change the answer.

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|-----|----------|----------|-----------|--------------|--------|------|
| 2026-08-04 | D001 | — | Report the three Quickshell 0.3.0 defects upstream; do not vendor or patch | (b) is a process-global that permanently breaks locking for any client | Upstream fixes (b) and VGS pins a newer Quickshell | Active | [Full](D001-quickshell-0-3-0-upstream-defects.md) |
| 2026-08-04 | D002 | — | GitHub -> Linear intake mirroring stays manual and documented as manual | Both automated options need owner-only access; wrong docs are worse than no automation | Owner enables the Linear GitHub integration or provisions a `LINEAR_API_KEY` secret | Active | [Full](D002-github-linear-intake-sync.md) |

---

## Format Reference

### What to Log
- Technology selections with alternatives considered
- Performance trade-offs (chose X over Y for reason Z)
- Significant path choices where conditions might change
- Research-informed decisions (reference research ID in rationale)

### What NOT to Log
- Variable names, small refactors, bug fixes
- Obvious choices with no realistic alternatives
- Standard pattern applications

### Status Values
- **Active**: Current decision in effect
- **Superseded by [DECISION_ID]**: Replaced by newer decision
- **Revisited**: Re-evaluated, with outcome noted

### Code Comments
Use `// REVISIT([DECISION_ID]):` in code to mark implementation points tied to decisions.
