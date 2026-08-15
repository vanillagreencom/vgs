---
applyTo: "AGENTS.md"
---

# AGENTS.md

Agent process instruction, not product documentation. Do not ask for its
content to be mirrored into `README.md`, and do not treat a change here as
needing user-facing release notes.

Do check that a claim added here matches the code it describes. Instructions in
this file are executed literally by agents, so a stale command, path, or flag
is a real defect.

Two checks read this file by exact string, so a pure reflow can break the build.
`scripts/check-validation-safety.sh` matches its sanctioned `qs -c vshell`
mentions per LINE, so wrapping one across two lines un-exempts it;
`scripts/test-validation-inventory.sh` substitutes the wrapped ``areas `go` …``
enumeration verbatim, and a no-op substitution silently disables that arm. After
rewrapping either, run `scripts/validate docs` and that safety check.
