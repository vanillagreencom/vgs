# Validation scripts

Read [../AGENTS.md](../AGENTS.md) for validation commands and live-session safety.

- `scripts/validate` owns the command manifest. Add or rename a check there with its implementation.
- `check-validation-inventory.py` owns CI coverage exceptions and checks manifest-to-workflow coverage. `test-validation-inventory.sh` exercises its refusal paths.
- `lib/validation_manifest.py` owns the area-marker parser. Keep marker syntax changes with its tests.
