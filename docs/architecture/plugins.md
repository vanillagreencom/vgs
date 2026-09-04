# Plugins, overlays and dependencies

Covers: config/vshell/, quickshell/vshell/Modules/Plugins/, quickshell/vshell/Services/

Bundled plugins are product UI. User packages can replace them only through the loader's declared override policy.

## Invariants

- A bundled-id collision without an override declaration stays inactive. Declared overrides inherit the bundled package's always-available status. `scripts/test-bundled-override.js` checks override policy.
- A replacement must pass startup and compilation checks before taking ownership. Failure restores the shipped package when its manifest is available. See `Services/PluginService.qml` and the override tests.
- Manifest identity is its path; ownership is its plugin id. A rescan evaluates every claimant of the id. See the scan and rescan paths in `Services/PluginService.qml`.
- Requirement reporting includes refused candidates, not only the current owner. `scripts/test-plugin-requirement-report.js` checks reporting.
- Command probes in the supported source set require a dependency declaration or a reasoned exclusion. `scripts/check-command-declarations.py` defines and checks that source set against `config/vshell/dependencies.json`.
- Package mappings must cover declared dependencies. `scripts/gen-package-metadata.py` checks the recipes against `packaging/optional-packages.json`.

## Decisions

[D005](../decisions/D005-dependency-version-constraints.md).
