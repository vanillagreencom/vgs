# shell/plugins/

First-party plugins, one directory per plugin id, each with `manifest.json` at its root. The contract is `docs/architecture/plugins.md`; the vgs-plugin skill holds the templates.

- A plugin imports Qt and Quickshell modules other than `Quickshell.Wayland`, `qs.Commons`, `qs.Ui`, and its own files. `scripts/check-plugin-boundary.py` refuses anything else.
- A plugin declares surfaces, never dependencies. The manifest refuses a `requires` key.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to its id, reads its settings through `setting(name, fallback)` and sizes itself with `implicitWidth` and `implicitHeight`.
- A dispatch or any other core action goes through a capability named in the manifest's `vgs.capabilities` and reached as `shell.<capability>`.
- A new plugin lands with its row in `scripts/qml-smoke.sh` that proves it is built and shown, and `scripts/check-manifests.js` passes.
- No figure in a manifest budget or a comment without the measurement that produced it.
