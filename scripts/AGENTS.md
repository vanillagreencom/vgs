# Validation scripts

Read [../AGENTS.md](../AGENTS.md) for validation commands and live-session safety.

- `scripts/validate` owns the command manifest. Add or rename a check there with its implementation.
- `check-validation-inventory.py` owns CI coverage exceptions and checks manifest-to-workflow coverage. Five suites exercise its refusal paths, one per surface: `test-validation-inventory.sh` (manifest and grammar arms), `test-validation-areas.sh` (documented area lists), `test-validation-dump.sh` (the grammar dump decoder), `test-validation-readers.sh` (runner against library) and `test-validation-ci-coverage.sh` (what CI runs). They share `lib/validation-testkit.sh`.
- `lib/validation_manifest.py` owns the area-marker parser. Keep marker syntax changes with its tests.
