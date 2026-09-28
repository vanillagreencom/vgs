# Hyprland layer

Covers: shell/Core/HyprlandLayer.qml, shell/Core/HyprlandLayer.js, bin/vgsh-hypr-judge, scripts/test-hyprland-layer.js, scripts/test-vgsh-hypr.sh, scripts/smoke/rows/hyprland.sh

Hyprland is configured in Lua alone; a classic `hyprland.conf` is unsupported. The shell writes one Lua file, the Hyprland layer, to `${XDG_STATE_HOME:-~/.local/state}/vgs/hypr/vgs.lua`, and one line in the user's `hyprland.lua` loads it. No plugin writes Hyprland configuration: a plugin declares its keys and blur rules as data in its manifest, and the core renders them. [D028](../decisions/D028-one-generated-hyprland-layer.md) records the choice, and its [Omarchy comparison](../decisions/D028-one-generated-hyprland-layer.md#omarchy-comparison) says where the layer follows Omarchy's Hyprland setup and where it differs.

## The file

`HyprlandLayer.js` renders the text, and `PluginLogic.hyprlandSection` gives it each plugin's part. In order:

1. A header saying the file is generated and naming `vgsh hypr render`, which writes it again.
2. The applied theme's window, group and group bar border colours, one `hl.config` call. `HyprlandLayer.BORDERS` maps each Hyprland option to its theme colour.
3. One section per enabled plugin whose manifest declares `hyprland`, by plugin id, headed `-- <id> <version>: binds and layer rules from its manifest`. Its layer rules come first, each named `<id>:<name>` for namespace `^vgs:<name>$`, then its binds, each `hl.dsp.global("<id>:<shortcut>")` with that shortcut id as its description.

- **Keys.** A key is written `MOD+MOD+KEY`, with the modifiers `SUPER`, `CTRL`, `ALT` and `SHIFT`. `PluginLogic.hyprlandKey` puts every part in upper case and the modifiers in that order, so two spellings of one key compare equal. A bind takes the key the plugin's `plugins[].keys` entry gives its shortcut, [configuration.md § shell.json keys](configuration.md#shelljson-keys), else the manifest's. A `null` entry unbinds it and leaves `-- unbound <id>:<shortcut>: shell.json sets its key to null`.
- **Conflicts.** A key two binds claim stays with the first plugin by id. The later bind is written as `-- skipped <key>: already bound by <id>`. A layer rule an earlier section wrote, with the same namespace and effects, is written once and noted.
- **Reports.** `vgsh plugin list` and the `listPlugins` IPC list each skipped bind, each `keys` name no bind declares, and a failed write, mkdir or reload among their errors, each led by `hyprland: `.
- **Plugin text.** The only plugin text in the file is data the manifest judge has checked: the id, the shortcut names, the keys, the namespaces, booleans and numbers. A version or theme name reaches a comment only, with every character outside printable ASCII replaced by `?`, so a line break cannot start Lua.

## When the shell writes it

`HyprlandLayer.qml` runs in the runner's shell only. It renders once the first scan is done, the configuration is ready and the theme file is read, and again whenever the plugins, `shell.json`, enablement or the theme change. A theme apply writes `theme.json`, so it reaches the layer too. The shell writes the file by rename, only when its bytes change, then runs `hyprctl reload config-only`. `vgsh hypr render`, the `renderHyprland` IPC, reads the file again, then writes it and reloads Hyprland whatever the bytes; a request made while a step runs starts its own cycle once that step ends.

`HyprlandLayer.step` decides each step, and the QML runs it. Quickshell's `FileView` writes nothing for the bytes it last read or wrote, and keeps a failed write's bytes as those, so after a failed write the next cycle reads the file first. A text whose directory or write failed is written again only once the text changes or a render asks for it, so an unwritable directory costs one attempt per change.

## The line

`vgsh hypr wire` keeps `pcall(dofile, "<state dir>/hypr/vgs.lua")` in `${XDG_CONFIG_HOME:-~/.config}/hypr/hyprland.lua`, first when it adds it. `vgsh hypr unwire` removes every copy. Both follow the theme include line's rule, [theme-wiring.md § Wiring text](theme-wiring.md#wiring-text): a whole-line match, no other byte changed, a symlink resolved and its target replaced with its mode kept, and the file never created. A state directory holding a quote, a backslash or a line break is refused, since the line holds it in a Lua string.

When the shell's first read finds no layer file, its first write also runs `vgsh hypr wire`, which wires `hyprland.lua` if it exists. After `unwire` the layer file stays, so no later start wires it again. The shell writes nothing under `~/.config/hypr/vgs/` and uses no `require` module name, so v1's generated files and modules are left alone.

The line is first, so every setting after it wins: a later `hl.config` value, `hl.unbind("<keys>")` with the keys spelt as the layer writes them, and `hl.layer_rule({ name = "<id>:<name>", enabled = false })`, which Hyprland v0.56.2 applies to the rule of that name. A key is better changed in `shell.json`, which needs no edit of Hyprland's files.

## Invariants

1. The manifest's `hyprland` key, a key's form, a row's `keys` and each plugin's binds are decided in `PluginLogic.js`; the text, its order, the conflicts, the one copy of a shared rule and the writer's sequence in `HyprlandLayer.js`. Enforced by `scripts/test-hyprland-layer.js`, whose controls each remove one rule from a copy of one of the two files; its step rows include a failed write followed by the same text and then a new one, and a render asked during a reload after the file was removed.
2. No plugin text reaches the layer's Lua but the judged data above, and a comment holds printable ASCII alone. Enforced by the same suite's manifest rows and its comment row.
3. `wire` never creates `hyprland.lua`, puts the line first, keeps a symlink and its target's mode, and refuses a state directory a Lua string cannot hold; `unwire` leaves the file byte for byte as it was. Enforced by `scripts/test-vgsh-hypr.sh` under a temporary HOME, with judge copies that create, skip the quoting refusal, wire on `unwire` and report every run as a change as its controls.
4. On the nested instance the first run wires the harness's `hyprland.lua` and changes no other line. Enabled plugins' binds and rules are loaded, and `SUPER+SPACE` and `SUPER+N` typed on the seat open the launcher and the inbox. A `keys` rebind, an unbind and a conflict reach Hyprland and `listPlugins`, a disabled plugin's section goes, the active border follows a theme apply, `render` writes a removed file again, `unwire` unloads the binds, and `configerrors` stays empty. Enforced by `scripts/smoke/rows/hyprland.sh`, which fails on a shell copy that writes the layer and never reloads Hyprland.

## Decisions

[D028](../decisions/D028-one-generated-hyprland-layer.md), [D021](../decisions/D021-theme-apply-writes-beside-each-destination.md).
