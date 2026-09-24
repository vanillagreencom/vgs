# shell/plugins/

First-party plugins, one directory per plugin id, each with `manifest.json` at its root. The contract is `docs/architecture/plugins.md`; the vgs-plugin skill holds the templates.

- Imports and names: the table in `.agents/skills/vgs-plugin/references/api.md` § Allowed imports; `scripts/check-plugin-boundary.py` refuses the rest.
- Every entry point declares `property var shell: null` and reads its capabilities from it, never from `bar`.
- A bar widget extends `BarWidget` from `qs.Ui`, sets `moduleName` to its id, reads its settings through `setting(name, fallback)` and sizes itself with `implicitWidth` and `implicitHeight`.
- A bar declares `leftSection`, `centerSection` and `rightSection`; the core mounts plugin widgets into them. A bar's own built-in widgets sit ahead of them and register through `shell.builtins`.
- A new plugin lands with its rows in `scripts/qml-smoke.sh`: one that reads a property back from the built instance to prove the kind's behaviour, and one planted-defect control that turns it red.
