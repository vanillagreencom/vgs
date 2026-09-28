# D032: A Settings plugin lists every plugin, and the manifest alone declares each plugin's settings page

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: VGS-508

**Context**: The plugin manager's user interface was a `manager` built-in of `vgs.bar`: a Plugins button and a small popup that listed every plugin with a switch and drew every schema form inline, [D013](D013-built-in-widgets-are-the-bar-plugins.md). A user could not see one plugin's details, capabilities or keys in one place, and plugin keybinds, which `hyprland.binds` declares and `shell.json` `keys` rebinds ([D028](D028-one-generated-hyprland-layer.md)), had no user interface. No manifest named an icon, and most first-party plugins declared no schema, so the list showed lower-case ids with a generic icon and nothing to change.

**Decision**: A first-party plugin, `vgs.settings` ("Settings"), is the manager's whole user interface. It lists every discovered plugin, itself included, and opens one settings page per plugin, drawn only from that plugin's manifest and the configuration. `vgs.bar` keeps its bar, its workspaces and its clock.

### The convention

Every plugin author follows one rule: the manifest is the settings page.

| Manifest key | The page shows |
|---|---|
| `name`, `icon`, `version`, `author`, `license`, `description` | The list row and the page header. `icon` is new and optional: a Lucide name from the shipped set, `shell/Ui/icons/Lucide.js`; a plugin without one shows `package`. |
| `capabilities` | One badge per capability. |
| `settings` | The default of each setting. Unchanged. |
| `schema` | One field per entry, in manifest key order. New optional entry keys: `min`, `max` and `step` for a `number`, and `group`, a section heading. Entries without a `group` come first, under no heading; each group then follows in the order its first entry appears. |
| `hyprland.binds` | The Keys section: one row per bind, never a schema entry. A row shows the key in effect, writes the plugin's `shell.json` `keys` entry, unbinds with an empty key and resets to the manifest's key. |

- A setting belongs in `schema` when a user would reasonably change it and the plugin reads it. A constant becomes a setting only when a user has a reason to change it.
- The judge, `PluginLogic.validateManifest`, enforces every new key: `icon` is a name in the shipped icon set, `min` and `max` are finite with `min < max`, `step` is positive, the three are refused on any type but `number`, the default lies inside the bounds, and `group` is a non-empty string. A written number outside `min` to `max` is refused by `settingRefusal`, like a value of the wrong type. `min`, `max` and `step` bound the control; `step` does not refuse a typed value.
- The judge reads the icon set from `Lucide.js` through a `.import` in `PluginLogic.js`, and `scripts/qml-library.js` resolves the same `.import` under node, so the shell and every offline reader decide with one judge and one list.
- A number with both `min` and `max` draws a slider with its value beside it; any other number draws a text field.

### The surface

- **Kinds.** `panel` (the Settings window), `bar-widget` (a gear button, placed where the manager button was: the shipped `bar.layout.right` lists `vgs.settings`), and `service` (the shortcut and the IPC). Capabilities: `manager`, `surfaces`, `shortcut`, `ipc` and `screens`.
- **Key.** `SUPER+M` opens and closes it, from the manifest's `hyprland.binds` as shortcut `toggle`, and `shell.json` `keys` rebinds it like every plugin key. No shipped plugin and no line of the shipped Hyprland layer binds `SUPER+M`: the launcher binds `SUPER+SPACE` and the notifications `SUPER+N`. A user's own `hyprland.lua` loads after the layer, so its own `SUPER+M` bind wins, [hyprland.md](../architecture/hyprland.md).
- **Window.** An unanchored `panel` summon: a `PanelWindow` layer surface on the `Overlay` layer that the summon host makes when summoned and destroys on hide, with `WlrKeyboardFocus.OnDemand`. It takes the keyboard when it maps, as the launcher's overlay does, and cannot hold it before it is opened, because no surface exists then. `center` placement ignores reserved space (an exclusive zone of `-1`), so the window is centred on the whole monitor, not on the area under the bar; every other placement keeps clear of reserved space as before. The gear button summons it without an anchor, on its own screen; the shortcut and IPC summon it on the focused monitor.
- **Size.** Width `min(size.window.width, screen width − 2 × size.window.gutter)` and height `size.window.heightShare × screen height`, read from the screen the `screens` capability gives. `size.window.width` is 600 and `size.window.heightShare` 0.5, both tokens.
- **Pages.** The root page is the plugin list: a search field and one row per plugin with its icon, name, version, `Bundled` or `Installed`, an error badge, an enabled switch and a chevron. A click or Enter pushes the plugin's page. The page header holds a `chevron-left` icon button, which pops back to the list, and the plugin's name as an underlined title with a `chevron-down` caret; a click on the title opens a menu of every plugin, icon and name, the current one checked, which jumps to that plugin's page. The page holds the description, author, version, license, source, capability badges, the enabled switch, the settings form and the Keys section; an installed plugin shows its `vgsh plugin update <id>` and `vgsh plugin remove <id>` commands. A disabled plugin's fields are read-only and say to enable it first; the Settings plugin's own page says `vgsh plugin enable vgs.settings` brings it back after a disable. Push and pop slide with `motion` tokens, so a `motion.scale` of 0 makes them instant. Escape pops a page, then hides the window.
- **Deep link.** `summon panel vgs.settings {"plugin":"<id>"}` opens that plugin's page, over IPC or through any plugin's `surfaces` capability; `{}` opens the list. A payload key other than `plugin` refuses the summon. An id no plugin has opens the list with a notice naming it.
- **Errors.** A row's errors are the plugin's failed builds and the problems the Hyprland layer reports for it, a skipped bind or a `keys` name no bind declares. The list shows a danger badge; the page shows each error.

### Core changes

- `managerRows` gains `icon`, `author`, `license`, `capabilities`, `source`, `binds` (each shortcut with the key in effect, its manifest default and the description the plugin registered) and `errors`. The Hyprland layer's problems reach the registry once, and `listPlugins` reads them from there too.
- The `manager` capability gains `setKey(id, shortcut, key)`: a key string rebinds, `null` unbinds, `undefined` removes the entry so the manifest's key applies. `PluginLogic.keyRefusal` and `PluginLogic.withKey` decide it, and a disabled plugin is refused, as for a setting.

### Design system additions

Every value `vgs.settings` draws with is a token read through `Theme`, and every control is a `qs.Ui` component:

- `size.window.width`, `size.window.heightShare` and `size.window.gutter`, for any window-like panel.
- `Menu` gains a `maxHeight` (token `menu.maxHeight`, about nine rows), scrolls inside it and keeps the highlighted entry in view, and jumps to the first entry whose text starts with the letters typed, reset after `menu.typeahead` milliseconds. `MenuItem` gains `checked`, a check mark. This is the dropdown menu; no second menu component exists.
- `ScrollArea`'s bar becomes a compact embedded bar: thin, shown while hovered or scrolling and faded otherwise, a draggable thumb with a minimum length, a click on the track that pages, and a gutter the content never sits under. The bar is one internal type of `qs.Ui` that `ScrollArea`, `Menu` and `Select` all use.
- `TitleButton`: a text button drawn as an underlined title with a caret, which names the current choice and opens its menu.
- The gallery shows each, and `scripts/qml-tests/` tests each under `qmltestrunner`.

### What each plugin gains

| Plugin | Name | Icon | Settings it gains, and why |
|---|---|---|---|
| `vgs.bar` | Bar | `panel-top` | `clockFormat` only, as before. The built-in lists `left`, `center` and `right` stay `shell.json` settings, since a list is no schema type. It loses `manager`, `surfaces`, its `panel` kind and the manager files. |
| `vgs.gallery` | Gallery | `swatch-book` | `placement`, an enum of `PluginLogic.PLACEMENTS`: it already reads it. |
| `vgs.themes` | Themes | `palette` | `placement`, likewise. |
| `vgs.launcher` | Launcher | `search` | None; its one key shows under Keys. Its constants are ceilings and look, not choices. |
| `vgs.notifications` | Notifications | `bell` | `duration`: how long a normal toast stays, in seconds, 2 to 30, step 1, default 8, which replaces the hard-coded 8 seconds. A low-urgency toast stays for the shorter of 5 seconds and that value. Its key shows under Keys. |
| `vgs.settings` | Settings | `settings` | None; its key shows under Keys. |

The launcher and the notifications take capitalised names, since the list shows `name`.

### Migration

A user `vgs.bar` row that lists `manager` in a section draws nothing for it, and the bar logs one line naming the move to `vgs.settings` and `vgsh plugin enable vgs.settings`, which places the gear in the right section when a user `bar` key replaces the shipped layout. Nothing rewrites the user file.

**Rationale**:

- One source per page: the manifest a plugin already ships, judged by the one judge. A third-party plugin gets a full page with no user-interface code, and a misspelt key or icon fails the manifest instead of drawing wrong.
- The manager listed like any other plugin can be disabled, rebound and deep-linked like any other, and `vgs.bar` goes back to drawing a bar, which removes the one built-in that needed a panel, the `manager` capability and `surfaces`.
- Keys are not settings: `shell.json` `keys` is read only by the Hyprland layer, so a schema entry for a key would have two writers.
- A centred layer surface built on summon holds no Wayland object while closed and cannot take focus while closed; ignoring reserved space for `center` is what makes the centre the monitor's.
- Extending `Menu` and `ScrollArea` keeps one component per job; the dropdown and the scrollbar are features of the existing components, and every scrolling list in the shell gains them.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Keep the manager in `vgs.bar` and enlarge its popup | The manager stays a built-in with a panel and a schema of its own, D013's revisit condition, and cannot be listed, disabled or rebound like a plugin. |
| Plugin-supplied settings pages in QML | Third-party user-interface code inside the settings window, and one page style per author. A data-only form draws every plugin the same way. |
| Keys as schema entries | Two writers for one `shell.json` key and a type the Hyprland judge already owns. |
| A schema list with a `key` field, as Omarchy's | The object form already carries each key once and keeps manifest order; a list would need a duplicate-key rule. |
| A new dropdown component beside `Menu` | Two menus with two keyboard models. |
| An anchored popup under the gear button | A popup under a bar button cannot be the centred window at half the monitor's height, and would differ from the shortcut's window. |

## Omarchy comparison

Checked against basecamp/omarchy main at `e332dc9`: `shell/plugins/README.md`, `docs/omarchy-shell.md`, `shell/plugins/*/manifest.json`, `shell/services/PluginRegistry.qml` and `default/omarchy/omarchy-menu.jsonc`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| Setup › Plugins in the command menu offers Enable, Disable, Add, Clone and Remove as menu actions; the actions pick a plugin from a list. | A Settings window lists every plugin and opens a page per plugin; install, update and remove stay `vgsh plugin` commands the page shows. | Taken: install and removal stay commands, with their confirmation in a terminal ([D007](D007-install-runs-no-plugin-code.md)). VGS adds a page per plugin because the owner asked to see a plugin's details, settings and keys in one place. |
| A bar widget manifest declares `barWidget.defaults` and `barWidget.schema`, a list of `{ key, type, label }`; some widgets name a `settingsForm` drawn by the bar's own code. | `settings` and `schema` at the manifest's top level for every kind, as before; no plugin-named form. | Taken: defaults plus a typed schema in the manifest. VGS keeps the keyed object and adds no hand-written forms, so every plugin, a service included, gets a page from data alone. |
| No manifest icon; menu entries carry Nerd Font glyphs. | A manifest `icon` from the shipped Lucide set. | VGS draws every icon from one vendored set ([D017](D017-templates-and-path-icons.md)), so the judge can refuse a name the shell cannot draw. |
| First-party plugins are enabled unless listed in `disabledPlugins[]`, and a built-in can be disabled. | The same rule, and `vgs.settings` is first-party. | Taken whole. |
| Keybinds live in the user's Hyprland Lua. | A Keys section that writes `shell.json` `keys`. | [D028](D028-one-generated-hyprland-layer.md): keys are judged data in `shell.json`, so the page can write them. |

**Revisit When**: A plugin needs a setting no schema type can hold, such as a list or a colour, or a second surface needs the manager's rows.

**Verification**: `scripts/test-plugin-logic.js` pins each new manifest and schema rule, the bound refusal and `keyRefusal`/`withKey`; `scripts/test-check-manifests.js` pins the icon rule offline; `scripts/test-qml-library.js` pins the `.import` resolution; `scripts/qml-tests/` covers `Menu`, `MenuItem`, `ScrollArea` and `TitleButton`. `scripts/smoke/rows/manager.sh` and `scripts/smoke/rows/settings.sh` drive `vgs.settings` in the nested sandbox: the list, self-listing, a page, a setting and a key written, enable and disable, the deep link, back navigation, the title menu jump, a scrollbar drag, the centring within one pixel, the 600 pixel and half-height size and the narrow-monitor clamp.

**References**: [D003](D003-everything-is-a-plugin.md), [D007](D007-install-runs-no-plugin-code.md), [D013](D013-built-in-widgets-are-the-bar-plugins.md), [D015](D015-tokens-are-a-judged-table.md), [D017](D017-templates-and-path-icons.md), [D028](D028-one-generated-hyprland-layer.md), [manager.md](../architecture/manager.md), [plugins.md](../architecture/plugins.md)
