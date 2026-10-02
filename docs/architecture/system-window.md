# The System window

Covers: shell/plugins/vgs.system/**, scripts/smoke/rows/system-window.sh

The System window is the `vgs.system` plugin: one window for every System section, such as sound, displays and network. Each section is a plugin of kind `pane`, and this window is the one enabled holder of the exclusive `panes` capability that lists and mounts them ([D088](../decisions/D088-system-panes.md), [capabilities.md](capabilities.md)). The Settings window stays the plugin manager: enablement, schema settings, keys and requirements ([settings-window.md](settings-window.md)).

## The window

- **Surface.** A `window` summon, which the window host builds as a Hyprland window titled System ([surfaces.md](surfaces.md)). It asks to be `size.panel.sm` plus `size.window.width` wide, or the monitor's width less `size.window.gutter` a side when that is less, and `size.window.heightShare` of the monitor's height tall, read from its `screens` capability.
- **Opening.** `SUPER+COMMA`, the manifest's `toggle` bind, opens and closes it. The service registers that shortcut and the `toggle` and `open` IPC functions, because the window's instance exists only while it is open. A section's own Settings link opens it through own-pane summon, `shell.surfaces.summon("pane", payload)`.
- **Sidebar.** A search `TextField`, then each enabled section under a `Section` heading of its `pane.group`, in the order `shell.panes.list` gives, then Shell & Plugins at the foot. The rows are `ListItem`s with one `ListCursor` ([D054](../decisions/D054-list-motion-is-one-cursor-in-qs-ui.md)). The list is bound to the capability's list, so a section enabled or disabled while the window is open joins or leaves it.
- **Shell & Plugins.** It opens the Settings window with `shell.run.detached(["vgsh", "ipc", "call", "shell", "summon", "window", "vgs.settings", "{}"])`, the command [settings-window.md](settings-window.md) names under Payload for another plugin, since `surfaces` opens only the caller's own surfaces.
- **Detail.** The section's icon and name, and a Show in bar `Switch` for a section with a bar widget (`hasWidget`), which calls `shell.panes.setPlaced`. Under them, `shell.panes.mount` puts the section in the page's container, which fills the room under the header or grows to the section's implicit height, and the page's `ScrollArea` scrolls it ([D050](../decisions/D050-container-layout-contract.md)). A refusal or a section that leaves the list shows as a notice over the detail.
- **Payload.** `{}` opens the section shown last, or the first. The last section is held in `Memory.js`, a library the engine loads once, so it outlives the window and is lost when the shell stops. `{"pane":"<id>", ...}` opens that section and hands the payload without `pane` to its `open()`. An id no enabled section has opens like `{}` with a notice naming it. A payload that is no object, a `pane` that is no string, or another key without `pane` throws out of `open()`, which refuses the summon and closes the window.
- **Keyboard.** `{}` leaves the keyboard on the sidebar's rows, and a deep link puts it in the section ([keyboard.md](keyboard.md) F3). Up, Down, Home, End and the pages move the selection and mount nothing. A letter selects the next row whose name starts with the letters typed. Enter or Right enters the selected section: it mounts the section unless it is shown, and the section takes the keyboard. Right never opens Shell & Plugins, since an arrow runs no action. Escape in the section returns the keyboard to the rows, and Escape on the rows closes the window. Ctrl+F focuses the search field from anywhere in the window. In the search field, typed text filters by name or id, Up, Down and Enter still move and enter, and Escape clears the query, then returns to the rows.

## Differences from Omarchy

Omarchy ships no settings window that mounts its sections: each section is a bar widget with its own flyout. Its command menu (`shell/plugins/menu/Menu.qml`) enters a submenu with Enter or Right and backs out with Escape, Left or Backspace. VGS takes Enter or Right to enter. It leaves Left to the mounted section, whose sliders and segmented controls use it, and backs out with Escape alone.

## Invariants

1. The sidebar lists exactly the enabled pane plugins, under their groups in the capability's order, and follows a section enabled or disabled while the window is open. Enforced by `scripts/smoke/rows/system-window.sh`, whose control is a copy of the window that keeps the list it read when it opened, which still lists a section disabled after that.
2. A deep link mounts its section with the rest of its payload, an unknown id opens with a notice, an own-pane summon mounts the caller's section, and each switch destroys the section before it in the window host's build records. Enforced by `scripts/smoke/rows/system-window.sh`.
3. Show in bar shows only for a section with a bar widget, and places and removes that widget through `panes.setPlaced` without disabling the section. Enforced by `scripts/smoke/rows/system-window.sh`.
4. A section taller than the room is mounted at its implicit height and the page scrolls it. Enforced by `scripts/smoke/rows/system-window.sh`, whose control is a shell copy whose `PaneHost` hands the holder no pane height, which cuts the section to the room.
5. The window is an application window as [surfaces.md](surfaces.md) invariant 2 states, and the sidebar's search field, headings and rows, the rule between the columns and the detail's icon, switch and section share their edges within one pixel. A keyboard alone opens it with `SUPER+COMMA`, moves, enters, leaves, searches, opens Shell & Plugins and closes it. Enforced by `scripts/smoke/rows/system-window.sh`.

## Decisions

[D044](../decisions/D044-application-windows-are-hyprland-toplevels.md), [D050](../decisions/D050-container-layout-contract.md), [D054](../decisions/D054-list-motion-is-one-cursor-in-qs-ui.md), [D068](../decisions/D068-keyboard-first-standard.md), [D088](../decisions/D088-system-panes.md).
