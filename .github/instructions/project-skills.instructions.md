---
applyTo: ".agents/skills/**"
---

# Project skills

`.agents/` is the kendex render tree, tracked so a clone works without kendex —
but the skills `kendex.toml` declares `source = "in-place"` are VGS's own and
nothing renders over them. That table is the register, and
`python3 scripts/lib/kendex_skills.py` lists what it says. Edit those here.
Every other `.agents/skills/<name>` is upstream output: fix the defect in
`vanillagreencom/kendex` and re-render, never in this repo.

A new project skill is written at `.claude/skills/<name>/SKILL.md`; `kendex
adopt skill <name>` moves it into `.agents/skills/<name>`, links each harness
dir at it, and declares it `source = "in-place"`. Adopt reads the Claude
harness unless `--harness` names another, and `.claude/skills` is where that
plain invocation looks.

The guards scope themselves: `scripts/check-doc-growth.py`,
`scripts/check-section-pointers.py` and `scripts/check-naming.sh` read the
register. Left by hand are a `CEILINGS` entry per markdown file and the
review-scope lists in `.coderabbit.yaml`, `.github/copilot-instructions.md` and
`review-bots.md`, which `scripts/check-owned-skills.py` names while missing.
Qodo is not among them — `.pr_agent.toml` has no path scoping at all, so it
reviews the whole render tree.
