# shell/plugins/

First-party plugins, one directory per plugin id, each with `manifest.json` at its root. The contract is `docs/architecture/plugins.md`; the vgs-plugin skill holds the templates.

- Imports and names: the table in `.agents/skills/vgs-plugin/references/api.md` § Allowed imports; `scripts/check-plugin-boundary.py` refuses the rest.
- Every entry point declares `property var shell: null` and reads its capabilities from it, never from `bar`.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to its id, reads its settings through `setting(name, fallback)` and sizes itself with `implicitWidth` and `implicitHeight`.
- A bar builds widgets only through `shell.widgets.create` and `shell.widgets.destroy`.
- A new plugin lands with its row in `scripts/qml-smoke.sh` that asserts it appears in `built`.
