# Plugin manager

Covers: bin/vgsh-plugin-judge, shell/plugins/vgs.bar/Manager.qml, shell/plugins/vgs.bar/ManagerPanel.qml, shell/plugins/vgs.bar/SettingField.qml

How plugins are discovered, enabled, disabled, installed, updated and removed, and what the manager's user interface may do. The plugin contract itself is [plugins.md](plugins.md).

## Mechanism

The manager is core: `Registry` lists and judges, `Plugins` enables, disables and writes settings, and `vgsh plugin` installs. Its user interface is the shipped bar's `manager` built-in: a button that opens the bar's own panel, which lists every discovered plugin with its enabled state and draws a settings form from each manifest's `schema`. The panel reaches the manager through the `manager` capability, which calls the same `setEnabled` the IPC does and writes a setting to every entry the plugin's instances read; a disabled plugin's setting is refused, since listing a third-party row would enable it. The panel shows each refusal on its plugin's row until a later call for that plugin succeeds.

- Enable and disable go through the shell's IPC, which writes the user file; the shell watches the file and re-derives the enabled set.
- Disable lists the id in `disabledPlugins` and changes nothing else: placement, settings rows and the active bar id stay, so re-enabling restores the exact screen. Enable unlists the id and gives a plugin a presence only when it has none: a bar becomes the active bar, an unplaced widget is placed in its default section, an unlisted third-party plugin of another kind is listed. Enabling a plugin that already has its presence is idempotent. `scripts/test-plugin-logic.js` pins each rule.
- The configuration files, their shape, their states and the write rule: [configuration.md](configuration.md). Nothing is built before the first scan and before the configuration is ready.
- Only the shell the runner started accepts a state-changing call; [runtime.md § Process](runtime.md#process).
- `add` clones into a staging directory beside `~/.config/vgs/plugins/`, runs the manifest judge, refuses an id another plugin owns or an occupied target, lists the id in `disabledPlugins` when the configuration would already enable it, then moves it into place. `update` refuses a modified checkout, prints the incoming diff, fast-forwards only and rolls back a version the judge refuses. `remove` deletes only `~/.config/vgs/plugins/<id>` holding that id, never a bundled plugin or a symlink. None runs plugin code or a git hook; each starts a rescan of a running shell. `bin/vgsh-plugin-judge` makes their decisions through `PluginLogic.js`, and `scripts/test-vgsh.sh` pins each rule, [D007](../decisions/D007-install-runs-no-plugin-code.md).

## Decisions

[D003](../decisions/D003-everything-is-a-plugin.md) and [D007](../decisions/D007-install-runs-no-plugin-code.md).
