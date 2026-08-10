---
applyTo: "scripts/**"
---

# Validation scripts

These scripts **are** this repo's test suite; there is no test framework. Judge
them as tests: a check whose failure path cannot be reached is vacuous. Look
specifically for

- a suppressed exit status (`|| true` swallowing a tool that failed to run),
- an empty result treated as a clean result,
- a snapshot or diff comparison that silently passes when collection failed.

Those exact bugs shipped here and had to be fixed; a linter that could not run
was reporting "passed", and a failed baseline snapshot was discarding damage
the after-snapshot plainly showed.

Never suggest validating this repo with `qs -c vshell` or
`qs -p quickshell/vshell` — see `AGENTS.md` § Never launch a second shell into
the live session. Never suggest `pkill quickshell`; signal by pid or process
group.
