# New plugin

Steps, in order. Each step names the command or file and the check that proves it.

1. Pick the id: `author.name`, lower case, dotted. First-party plugins use `vgs.`; nobody else may.
2. Pick the kinds from the table in [`../references/api.md`](../references/api.md). A plugin with a bar presence and a popup declares `bar-widget` and `panel`; a background job declares `service`.
3. Scaffold: `.agents/skills/vgs-plugin/scripts/vgs-plugin new <id> --kinds <kinds>`. It writes the directory under `shell/plugins/` (or `--dir` elsewhere) from the templates and runs the manifest check.
4. Fill each entry point. Keep the template's imports; add only what the rules allow. Read settings through `setting()`; read theme through `Color` and `Style`.
5. If the plugin acts on the compositor, add the capability to `vgs.capabilities` and call `shell.<capability>` from the entry point. Nothing else in the manifest's `vgs` block.
6. Check: `.agents/skills/vgs-plugin/scripts/vgs-plugin check <dir>` runs the manifest judge and the boundary check on that directory. Fix every line it prints.
7. Place it: for a bar widget, add `{ "id": "<id>" }` to a section of `bar.layout` in `~/.config/vgs/shell.json`, or run `bin/vgsh plugin enable <id>` against a running shell. For other kinds, `bin/vgsh plugin enable <id>`.
8. Prove it in the sandbox: add a row to `scripts/qml-smoke.sh` beside the bundled plugins' rows, asserting `barWidgets` lists the widget or the plugin appears enabled in `listPlugins`, then run `scripts/validate qml`.
9. Never test against the live shell. `scripts/qml-smoke.sh` is the only place a second shell starts.
10. Write no figure the run did not print. If the smoke prints `rss_kib`, that is the number; nothing else is.
