# scripts/

Validation and measurement scripts. A script here reads the repository and the nested sandbox; it never signals, restarts or drives the live shell.

- `scripts/validate` owns the validation manifest. A check is added there with its implementation, and CI runs the manifest, not a second list.
- A failed tool invocation never becomes an empty successful result. A check that cannot run exits 77 and names what is missing; 77 is not a pass.
- Every check ships one must-fail control beside it, named `test-<check>` (for `check-manifests.js`, `check-plugin-boundary.py`) or `test-<subject>` for a script under `bin/` or `shell/Core/` (`test-vgsh.sh`, `test-plugin-logic.js`), that plants the defect the check exists to catch. `validate` and `qml-smoke.sh` are the runners and have none.
- `qml-smoke.sh` is the only place a shell starts from here. Its sandbox is built from the repository alone, its runtime dir is a short name under the host's `XDG_RUNTIME_DIR`, and it reads the shell's per-instance log file, not redirected stdout.
- A check that judges a manifest calls `shell/Core/PluginLogic.js` through node; it never re-implements a rule.
- The memory sampler, the heap-profile attributor and the event-latency benchmark were carried over from the previous shell and still address its paths; `docs/architecture/memory.md` says so. A budget quoted anywhere names the tool and the run that produced it.
