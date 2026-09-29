# Settings

`vgs.settings`: the window that lists every plugin the shell found and opens a page for each, with its details, its settings and its keys. It lists itself, so it can be disabled, rebound and opened at one plugin's page like any other plugin.

## Opening it

| Path | How |
|---|---|
| Shortcut | `SUPER+M` opens and closes it on the focused monitor. The service registers `vgs.settings:toggle`, and the manifest binds it in the Hyprland layer the shell writes. Change the key under Keys on the plugin's own page. |
| Bar | The gear in the bar's right section, where the shipped layout places it. A click opens and closes the window on that bar's monitor. |
| IPC | `vgsh ipc call vgs.settings invoke toggle '<payload>'` or `... invoke open '<payload>'`, or the host's `vgsh ipc call shell summon panel vgs.settings '<payload>'`. |

The payload is `{}` for the list, or `{"plugin":"<id>"}` for that plugin's page. An id no plugin has opens the list with a notice naming it. Any other key refuses the summon with `refused: open-failed=vgs.settings`. Any plugin with the `surfaces` capability, or the launcher's menu, opens a page the same way.

## The window

- A window centred on the monitor, 600 pixels wide, or the monitor's width less a margin a side on a narrower one, and half the monitor's height tall. It takes the keyboard when it opens.
- The list: a search field and one row per plugin with its icon, name, version, `Bundled` or `Installed`, a red badge counting its errors, its switch and a chevron. Up and Down in the search field move the highlighted row; Enter or a click opens its page.
- A plugin's page: a back button and the plugin's name as a title. A click on the title opens a menu of every plugin, the current one checked, that jumps to another plugin's page; typing letters there jumps to the plugin whose name starts with them.
- The page shows the description, the capabilities, each error, the switch, the author, version, licence and source, and for an installed plugin its `vgsh plugin update` and `vgsh plugin remove` commands.
- Settings: one field per entry of the plugin's `schema`, grouped under the entry's `group`. A number with a `min` and a `max` is a slider.
- Keys: one row per key the plugin's manifest binds. Type a key such as `SUPER+SHIFT+M`, empty the field or press the cross to unbind it, and press the arrow to go back to the manifest's key. The key is written to the plugin's `keys` in `~/.config/vgs/shell.json`.
- A disabled plugin's fields are read-only until it is enabled again.
- Escape goes back to the list, then closes the window.

Install, update and remove stay `vgsh plugin` commands in a terminal.

## Turning it off

`bin/vgsh plugin disable vgs.settings`, or its own switch, removes the window, the gear and the shortcut. `bin/vgsh plugin enable vgs.settings` brings them back, and places the gear in the right section when your `shell.json` has a `bar` key of its own.
