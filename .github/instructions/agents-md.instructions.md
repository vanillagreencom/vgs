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

Two checks read this file by exact string, so a pure reflow can break the build —
in checks the `docs` area does not run. `scripts/check-validation-safety.sh`
matches its sanctioned direct-launch mentions per LINE: wrap one and it is no
longer exempt. `scripts/test-validation-inventory.sh` substitutes the wrapped
``areas `go` …`` enumeration verbatim and asserts the guard then REFUSES, so a
substitution gone no-op fails there too. Both are loud. After rewrapping, run
`scripts/validate all`, or that safety check with `--require-static` plus
`scripts/test-validation-inventory.sh`.
