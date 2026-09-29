# scripts/

Validation and measurement scripts. A script here reads the repository and the nested sandbox. Nothing under `bin/` or `shell/` may load a file here, since an install ships without `scripts/`: a helper the runtime needs goes in `bin/lib/`, and the `runtime_reads_no_scripts` check in `validate` refuses the load.

- A check is a row in `scripts/validate` with its must-fail control beside it, named `test-<subject>` for the script it exercises. `qml-smoke.sh` is a runner and has none; the checks `validate` makes itself have theirs in `test-validate.sh`.
- What the sandbox needs, how it exits and where the shell's log is: `docs/architecture/validation.md` and `docs/architecture/runtime.md` § Process.
- What a memory figure may claim and how the sampler finds the shell: `docs/architecture/memory.md`.
- Use `scripts/validate --list` to inspect the affected checks, then omit `--list` to run them once. Selection defaults to the default branch's merge base; `--changed BASE` narrows a fix round, and `--full` explicitly requests every row. The input globs beside each manifest row include its shared dependencies. An unmapped source input selects the full area; docs and harness-only changes do not start the product smoke.

- `sandbox-shots.sh` captures the sandbox's surfaces as PNGs under `tmp/` for visual evidence. It is a runner like `qml-smoke.sh`; its capture guards in `smoke/shot.sh` have their control.
- Smoke rows live under `scripts/smoke/rows/`. The runner fixes their order because later rows use earlier state. Only `scripts/smoke/harness.sh` owns the sandbox lifetime; its teardown lives in `scripts/smoke/teardown.sh`, which it sources.
- Smoke fixtures live under `scripts/smoke/fixtures/plugins/`. Offline validation checks every fixture. Runtime refusal fixtures belong to the rows that assert their refusal. `scripts/smoke/fixtures/slack/` is not a plugin: it is a synthetic Slack configuration, a workspace list and one disk-cache entry, that the notifications row and `sandbox-shots.sh` place under the sandbox's configuration.
