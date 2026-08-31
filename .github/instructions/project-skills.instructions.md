---
applyTo: ".agents/skills/**"
---

# Project skills

`.agents/` is the kendex render tree, tracked so a clone works without kendex —
but three skills inside it are VGS's own and are never rendered over:
`vgs-distro-publish`, `vgs-release` and `vshell-dev`. `kendex.toml` declares
each with `source = "in-place"`, and that table is the register. Edit those
here. Every other `.agents/skills/<name>` is upstream output: fix the defect in
`vanillagreencom/kendex` and re-render, never in this repo.

A new project skill is written at `.claude/skills/<name>/SKILL.md`; `kendex
adopt skill <name>` moves it into `.agents/skills/<name>`, links each harness
dir at it, and declares it `source = "in-place"`. Adopt reads the harness path,
so authoring straight into `.agents/` leaves it nothing to find. Then add an
entry wherever a guard or bot scopes to the owned set — `WATCHED_SURFACES` and `CEILINGS` in `scripts/check-doc-growth.py`,
`OWNED_ROOTS` in `scripts/check-section-pointers.py`, `candidate_paths` in
`scripts/check-naming.sh`, and the review-scope carve-outs in `.coderabbit.yaml`,
`.pr_agent.toml` and `.github/copilot-instructions.md`.
