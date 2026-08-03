---
applyTo: "vstack*.toml"
---

# Agent-harness configuration

These sections are **not** all hand-authored. `[agent-frontmatter.*]` and
`[agent-skills]` in `vstack.toml` are generated and rewritten by
`vstack refresh` from upstream defaults, so findings about the values there
(model choice, effort, sandbox-mode) belong upstream — an in-repo edit is
overwritten on the next refresh. This has already produced a wrong finding
about the Codex `danger-full-access` sandbox mode.

`vstack.settings.toml` is public by design: non-secret project defaults,
committed deliberately, documented inline. Every credential lives in gitignored
`.env.local`. Do not report values here as leaked secrets, and do not ask for
these options to be documented in `README.md`.
