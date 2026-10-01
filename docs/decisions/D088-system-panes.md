# D088: System sections are pane plugins mounted by the one panes holder

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: VGS-691

**Refines**: [D013](D013-built-in-widgets-are-the-bar-plugins.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D044](D044-application-windows-are-hyprland-toplevels.md)

**Context**: The System plan needs one System window with sections for sound, displays, Bluetooth, network, VPN, mouse and keyboard. Each section must remain its own plugin, because it also owns its bar widget, its flyout and its service. Before this decision, a plugin could draw only in a surface the core hosted for that plugin. No plugin could draw one section inside another plugin's window without using the host plugin's `shell` object, which would give it the wrong settings and capabilities.

**Decision**: VGS adds kind `pane` and capability `panes`. A pane plugin declares `pane: { group, order }` and an entry point with `open(payloadJson)` and `close()`. One enabled plugin holds the exclusive `panes` capability. That holder lists enabled pane plugins as `{ id, name, icon, group, order, placed, hasWidget }`, mounts one pane at a time into its own item tree, and gives the mounted pane the pane plugin's own scoped `shell`, not the holder's. A mounted pane is recorded under the holder's host key and is destroyed when the holder switches panes or closes.

A plugin can call `shell.surfaces.summon("pane", payload)` to open the holder's window with its own pane id in the payload. The call answers `refused: panes=no-holder` when no enabled holder exists.

A pane's `configure.set` writes every settings entry the plugin reads, through `PluginLogic.settingTargets`. This matches the manager's multi-target contract. A pane plugin that has a service, a bar widget and a pane therefore reads the same setting in its service, widget, pane and Settings page.

`panes.setPlaced(id, placed)` applies the existing placement rule to listed pane plugins only. It never writes `disabledPlugins`.

**Rationale**:

- The pane contract satisfies D013's revisit condition without adding a free-form child-plugin slot to every plugin surface.
- The holder stays the only owner of the application window. Section plugins stay independent units with their own manifests, settings, services and validation rows.
- The scoped `shell` keeps capability boundaries intact. A pane cannot use the holder's `panes` capability unless its own manifest names it.
- Multi-target writes remove split settings. A user can edit a section setting in the pane or in Settings and every running instance sees the same value.

## Omarchy comparison

Checked against basecamp/omarchy `main`, read from `/home/method/dev/vgs/tmp/omarchy-ref` on 2026-10-01. Omarchy ships one plugin per section under `shell/plugins/panels/`, such as audio, Bluetooth, network, monitor and Tailscale. Each section is a bar widget with its own flyout. Omarchy has no settings application that mounts those sections into one window.

VGS takes Omarchy's per-section split. VGS differs by adding a pane contract and one holder window, because the System plan needs a macOS-style sidebar and detail pane while keeping each section as its own plugin.

**Alternatives considered**:

| Alternative | Why rejected |
|---|---|
| Put every System section in one `vgs.system` plugin | One plugin would own every service and every setting. A section could not be enabled, updated or reviewed alone. |
| Give each section its own `window` | The user would get many toplevels and no shared sidebar. |
| Let the holder pass its `shell` to child QML | The pane would receive the holder's capabilities and settings, which breaks the scoped API boundary. |
| Make panes another summoned surface | The host is inside a holder window, not a Wayland surface. A summonable kind would create another surface instead of filling the holder. |

**Revisit When**: Two enabled application windows must host the same pane set at the same time, or a pane must survive while its holder window is closed.

**Verification**: `scripts/test-plugin-logic.js` pins the `pane` kind, the `pane` manifest key, `panes` exclusivity and pane multi-target setting writes, each with a control. `scripts/smoke/rows/panes.sh` reads a mounted pane's manifest id and capabilities, switches panes, refuses a second holder, opens the holder through own-pane summon, checks a setting through the pane and Settings, and drives a keyboard path through the mounted pane.

**References**: [plugins.md](../architecture/plugins.md), [capabilities.md](../architecture/capabilities.md), [surfaces.md](../architecture/surfaces.md), [plugin-manifest.md](../architecture/plugin-manifest.md)
