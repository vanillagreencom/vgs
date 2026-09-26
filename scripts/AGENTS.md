# scripts/

Validation and measurement scripts. A script here reads the repository and the nested sandbox.

- A check is a row in `scripts/validate` with its must-fail control beside it, named `test-<subject>` for the script it exercises. `qml-smoke.sh` is a runner and has none; the checks `validate` makes itself have theirs in `test-validate.sh`.
- What the sandbox needs, how it exits and where the shell's log is: `docs/architecture/runtime.md` § Validation and § Process.
- What a memory figure may claim and how the sampler finds the shell: `docs/architecture/memory.md`.
