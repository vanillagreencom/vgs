# New plugin

Steps, in order. Each step names the command or file and the check that proves it.

1. Pick the id: `author.name`, lower case, dotted. The manifest judge refuses any other shape.
2. Pick the kinds from the table in [`../references/api.md`](../references/api.md). A plugin with a bar presence and a popup declares `bar-widget` and `panel`; a background job declares `service`.
3. Scaffold: `.agents/skills/vgs-plugin/scripts/vgs-plugin new <id> --kinds <kinds>`. It runs the manifest judge before writing, writes the directory under `shell/plugins/` (or `--dir` elsewhere) from the templates, and runs the manifest and boundary checks on it.
4. Fill each entry point. Keep the template's imports and its `shell` property. Read settings through `shell.settings` or, in a widget, `setting()`; read colours through `Color` and `Style`. Put every default in the manifest's `settings`.
5. For every core API the plugin uses (the compositor, a shortcut, IPC, its own settings, a process, notifications, the lock, polkit, screens), add the capability to `capabilities` and call `shell.<capability>` from the entry point. The capability table in [`../references/api.md`](../references/api.md) lists each. A plugin that writes its own settings declares a `schema`.
6. Check again after editing: `.agents/skills/vgs-plugin/scripts/vgs-plugin check <dir>`. Fix every line it prints.
7. Place it: for a bar widget, `bin/vgsh plugin enable <id>` against a running shell puts it in its default section; for other kinds, the same command lists it. Without a running shell, edit `~/.config/vgs/shell.json` (or the file under `XDG_CONFIG_HOME`).
8. Prove it in the sandbox with rows in `scripts/qml-smoke.sh` beside the fixture plugin's rows, then run `scripts/validate qml`. Presence in `built` proves bookkeeping only; each kind needs its behaviour read back from the instance through `readInstance`, plus one planted-defect control that turns the row red:
   - a service: a property proving its action ran, and the record gone after disable;
   - a bar widget: the widget listed in its section and a property it derives from its settings;
   - a bar: the widgets mounted per section and the surface and reserved space read from `hyprctl`;
   - a capability: a property proving the delivered API is callable.
9. Never test against the live shell. `scripts/qml-smoke.sh` is the only place a second shell starts.
