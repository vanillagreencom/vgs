# New plugin

Steps, in order. Each step names the command or file and the check that proves it.

1. Pick the id: `author.name`, lower case, dotted. The manifest judge refuses any other shape.
2. Pick the kinds from the table in [`../references/api.md`](../references/api.md). A plugin with a bar presence and a popup declares `bar-widget` and `panel`; a background job declares `service`.
3. Scaffold: `.agents/skills/vgs-plugin/scripts/vgs-plugin new <id> --kinds <kinds>`. It judges the manifest before writing, writes the directory under `shell/plugins/` (or `--dir` elsewhere) from the templates, and runs the manifest and boundary checks on it.
4. Fill each entry point. Keep the template's imports and its `shell` property. Read settings through `setting()` or `shell.settings`; read colours through `Color` and `Style`.
5. If the plugin acts on the compositor, add the capability to `vgs.capabilities` and call `shell.<capability>` from the entry point.
6. Check again after editing: `.agents/skills/vgs-plugin/scripts/vgs-plugin check <dir>`. Fix every line it prints.
7. Place it: for a bar widget, `bin/vgsh plugin enable <id>` against a running shell puts it in its default section; for other kinds, the same command lists it. Without a running shell, edit `~/.config/vgs/shell.json` (or the file under `XDG_CONFIG_HOME`).
8. Prove it in the sandbox: add a row to `scripts/qml-smoke.sh` beside the fixture plugin's rows asserting the plugin appears in `built`, then run `scripts/validate qml`.
9. Never test against the live shell. `scripts/qml-smoke.sh` is the only place a second shell starts.
