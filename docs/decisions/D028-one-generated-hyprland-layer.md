# D028: The shell writes one Hyprland layer from the theme and plugin manifest data

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Revisited

**Research**: VGS-489

**Context**: vgs uses Lua for all Hyprland configuration. Hyprland v0.56.2 does not read `hyprland.conf` when `hyprland.lua` exists. The launcher and the notifications register global shortcuts that each user bound by hand, and their glass blurs only when a layer rule asks for it. The `hyprland` theme target kept a `source` line in `hyprland.conf`, so on a Lua session it was skipped and the borders never followed the theme. v1 wrote Lua modules under `~/.config/hypr/vgs/` that a user's `hyprland.lua` still loads with `require("vgs.…")`.

**Decision**: The shell core writes one Lua file, the Hyprland layer, to `<state dir>/hypr/vgs.lua`, and one line in the user's `hyprland.lua`, `pcall(dofile, "<that file>")`, loads it. [hyprland.md](../architecture/hyprland.md) is the contract.

- **Content.** A header naming `vgsh hypr render`, the applied theme's border colours, then one section per enabled plugin that declares `hyprland` data in its manifest, headed by the plugin's id and version.
- **Plugin data.** A manifest declares data alone: `binds`, each a shortcut it registers and a default key, and `layerRules`, each a `^vgs:<name>$` namespace with blur and `ignoreAlpha`. The core renders it, and every bind dispatches `global` to `<plugin id>:<shortcut>`.
- **User keys.** A `plugins[]` row's `keys` in `shell.json` rebinds a shortcut, or unbinds it with `null`, and `configError` judges it.
- **Conflicts.** A key two plugins claim goes to the first by id. The loser is a comment and a `listPlugins` error. An identical layer rule is written once.
- **Writes.** The shell writes again on every plugin, configuration and theme change, only when the bytes change, and then runs `hyprctl reload config-only`.
- **The line.** `vgsh hypr wire` keeps the line first and `vgsh hypr unwire` removes it, under D021's include-line rule: never create the file, edit no other line, add nothing twice, remove it whole. The shell runs `wire` once, after its first write, when no layer file existed before.
- **Hyprland is no theme target.** The `hyprland` target and its `hyprland.conf` wiring are gone. The layer replaces D021's include line for Hyprland, and no other target changes.

**Rationale**:

- One file and one line leave one thing to install, repair and remove. A theme target beside the plugin layer would be a second line.
- Plugin-authored Lua in the compositor's configuration would run plugin code outside the shell, which [D007](D007-install-runs-no-plugin-code.md) keeps out of install and [D010](D010-facade-scope-not-sandbox.md) does not sandbox. Data the manifest judge checks lets only an id, names, keys, namespaces, booleans and numbers reach the Lua.
- A bind can only dispatch to the plugin's own id, so no plugin can bind another's shortcut.
- Keys in `shell.json` go through the same judge and the same file as every other setting, so no user edits Hyprland's files to move a key.
- The line is first, so the user's own `hl.config`, `hl.unbind` and `hl.layer_rule` after it win.
- `dofile` on an absolute path in the state directory writes nothing under `~/.config/hypr/vgs/` and takes no `require` module name, so v1's files and modules are left alone. `pcall` keeps a missing layer file from stopping the rest of `hyprland.lua`, on the owner's instruction. It also hides a Lua runtime error inside the layer: the layer's remaining lines are skipped and no list shows the error. A field a binding function refuses still reaches `hyprctl configerrors` ([runtime-hyprland.md](../architecture/runtime-hyprland.md)). The layer is rendered from judged data alone, and `scripts/smoke/rows/hyprland.sh` reads the binds, the border and `configerrors` back from the compositor.
- `config-only` reloads the configuration without reconfiguring the monitors, so a key or theme change does not reset the outputs.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| The `hyprland` theme target renders the layer | The border colours would sit in the theme's file and the plugin data in another, two lines to keep, and a plugin's keys would change only on a theme apply. |
| Each plugin ships a Lua fragment | Plugin-authored code would run in the compositor's configuration. |
| One file per plugin, each with its own line | Many lines to keep and remove, and no place to settle a conflict. |
| Keep a `hyprland.conf` path | Hyprland v0.56.2 ignores it when `hyprland.lua` exists, and a `.conf` cannot load Lua. |

## Omarchy comparison

Checked against basecamp/omarchy main at `b18ab49`: `config/hypr/hyprland.lua` and `default/hypr/{bootstrap,omarchy,require_optional,toggles}.lua`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| Omarchy ships and owns the user's whole `hyprland.lua`. It `dofile`s `bootstrap.lua`, which clears its modules from `package.loaded` and prepends `~/.local/state`, `~/.config` and `$OMARCHY_PATH` to `package.path`. It then `require`s `default.hypr.omarchy`, and the user's `hypr.*` modules load after it. | One `pcall(dofile, …)` line, first in a `hyprland.lua` the user owns. | Taken: defaults first and the user's settings after, so the user wins. It differs because VGS is a shell on the user's Hyprland configuration, not a distribution, so it owns one line and nothing else ([D021](D021-theme-apply-writes-beside-each-destination.md)). An absolute `dofile` changes no `package.path`, needs no `package.loaded` purge on reload, and takes no module name that v1's `vgs.*` modules could collide with. |
| The generated theme, `omarchy.current.theme.hyprland`, lives under `~/.local/state` and loads after the defaults. | One generated file under `~/.local/state/vgs/hypr/`: the theme's border colours, then each enabled plugin's section. | Taken: generated state lives under `~/.local/state`. One file, because everything in it is generated and small. |
| The opt-out is a Lua global set before the `require`, `omarchy_default_bindings = false`, and the user rebinds in their own Lua. | A `plugins[]` row's `keys` in `shell.json`, a key or `null`, judged by `configError`; `vgsh hypr unwire` removes the whole layer. | No edit of Hyprland's files is ever needed, and a misspelt key is refused, where a misspelt Lua global does nothing. |
| `require_optional` loads a module only when `package.searchpath` finds it, so an error inside a module it finds still surfaces. | `pcall` around the line. | On the owner's instruction: a broken or missing layer never stops `hyprland.lua`. The rationale above names what that hides and what reads it back. |
| `toggles.lua` stopped loading older generated Lua that "could carry an injected USB device name". | The layer holds text from third-party manifests and `shell.json`. | Taken: no supplied text can become code. Each string in a Lua literal is judged to characters that cannot end it: the id, the shortcut names, a normalised key and a `^vgs:<name>$` namespace. A version or theme name reaches only a comment, with every character outside printable ASCII replaced. `scripts/test-hyprland-layer.js` renders a version and a theme name holding `\nos.exit()`, and its `comment text` control removes that replacement from a copy of the renderer and fails. |

**Revisit When**: Hyprland stops running `hyprland.lua` top to bottom or drops `hl.dsp.global`, or a plugin needs a Hyprland setting other than a bind or a blur rule.

**Verification**: `scripts/test-hyprland-layer.js` covers the manifest key, the key grammar, `keys`, the effective binds and the rendered text, with a control per rule. `scripts/test-vgsh-hypr.sh` covers `wire` and `unwire`, with judge copies as controls. `scripts/smoke/rows/hyprland.sh` reads the nested instance back: first-run wiring, binds, key presses reaching both plugins, a rebind, an unbind, a conflict, a disabled plugin's section, the border following a theme apply, `render`, `unwire`, and an empty `configerrors`.

**References**: [D021](D021-theme-apply-writes-beside-each-destination.md), [D007](D007-install-runs-no-plugin-code.md), [D010](D010-facade-scope-not-sandbox.md), [D012](D012-core-owns-lent-objects.md), [hyprland.md](../architecture/hyprland.md)

## Revisit Outcome (2026-09-28, VGS-513)

The decision holds. The layer gains one constant core section, the floating TUIs' window rules, after the border colours and before the plugin sections: one `hl.window_rule` each for the app-ids `org.vgs.tui`, `org.vgs.tui.wide` and `org.vgs.tui.tall`, which floats the window, centres it and gives it 875 × 600, 1200 × 720 or 875 × 900 ([hyprland.md § The file](../architecture/hyprland.md#the-file)). Plugins still declare only binds and layer rules, and no plugin text reaches a window rule: the core alone holds the app-ids, the class patterns and the sizes, in `HyprlandLayer.TUI_WINDOWS`. A user disables one by name after the line, `hl.window_rule({ name = "vgs:tui", enabled = false })`, as for a layer rule. Hyprland v0.56.2 accepts the fields with an empty `configerrors`, floats, centres and sizes a window of each class, and honours the disable: `scripts/smoke/rows/hyprland.sh` reads each back on the nested instance.

Omarchy (basecamp/omarchy `main` at `e332dc9`) gives windows tagged `floating-window` the same float, centre and 875 × 600 in `default/hypr/apps/system.lua`, and tags a list of classes with it through `o.window` in `default/hypr/helpers.lua`, which sets `match.class` and calls `hl.window_rule`. VGS takes the float, the centre and the default size. It differs in two ways:

- **Exact classes, no tag.** Three sizes would need three tags, and a tag is a name any other rule, a user's included, can add to an unrelated window. Each rule matches its app-id anchored, with its dots escaped, so the default rule never matches `org.vgs.tui.wide`.
- **In the generated layer.** Omarchy's rules live in the configuration it ships and owns. VGS owns one line of the user's `hyprland.lua`, so its rules live in the layer that line loads, and a user's rule after the line wins.

## Revisit Outcome (2026-09-29, VGS-582)

The decision holds. The layer gains a second constant core section after the floating TUIs' rules: `vgs:window`, one `hl.window_rule` that floats and centres every window of the shell's class, `org.vgs.shell`, with no size ([D044](D044-application-windows-are-hyprland-toplevels.md)). No plugin text reaches it, and a plugin still writes no window rule. A user disables it by name after the line, as for the floating TUIs' rules.

## Revisit Outcome (2026-09-29, VGS-585)

[D048](D048-theme-owned-hyprland-appearance.md) refines this decision. The one generated layer now writes theme-owned Hyprland appearance before the floating TUI rules and application window rule: borders, radius and motion, each behind a manifest-declared switch. The core still names no plugin. A plugin declares `hyprland.appearance` in its manifest, and the first enabled declaration by plugin id owns the switches. If no plugin owns a group, the core default keeps border and radius output on and motion output off.

## Revisit Outcome (2026-09-29, VGS-596)

The decision holds. The layer gains a third constant core section after the shell window rule: overlay keyboard capture. [D067](D067-overlay-keyboard-capture.md) records it. Plugins still declare only binds and layer rules as data. The capture section repeats enabled plugin binds inside the `vgs:capture` submap and wraps `hl.dsp.focus` and `hl.bind` to learn the user's default-map directional focus binds. The wrapper uses runtime values handed to `hl.bind`; no user key text is rendered into the generated file. The section enters and leaves capture by reading `hl.get_layers()` for mapped `vgs:overlay` layers on layer open, layer close and config reload.
