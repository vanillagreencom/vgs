# Passive layers

Covers: shell/Core/Layers.qml, shell/Hosts/LayerHost.qml, scripts/smoke/rows/layers.sh, scripts/smoke/fixtures/plugins/acme.layers/**

A passive layer is a surface a plugin draws in without taking the keyboard: a notification stack, an on-screen display, anything that shows while the user keeps typing into another window.

`layers` is a capability rather than a kind: [D026](../decisions/D026-passive-layers-are-a-capability.md).

## The contract

- A plugin names `layers` in its manifest's `capabilities` and calls `shell.layers.show(component)` with a `Component` declared in its own files. It answers a disposer. Something that is not a component is refused with `refused: layers=not-a-component`, and a component that is not ready with `refused: layers=component-not-ready status=<n>`.
- `shell/Core/Layers.qml` holds each registration; `shell/Hosts/LayerHost.qml` builds one surface per screen for each, and one copy of the component inside it. The core assigns the copy its `screen` after creation, as it does for a background; a copy that does not declare `screen` is destroyed, logged as `layers: <plugin id> content not built on <screen>: <reason>`, and maps no surface.
- The surface is anchored on every edge of its screen, on the overlay layer, under the namespace `vgs:layer`. It respects the space other layers reserve, so it covers the screen less the bar, and it reserves none. It never takes keyboard focus.
- Pointer input reaches the surface only where the content says: everywhere while the content's `inputAll` is true, otherwise the rectangle of its `inputItem`, and nowhere when it names none. Every other press passes through to what is below.
- `ToastHost` follows the same layer placement rule for `vgs:toast`: the compositor keeps it clear of the bar's reserved space, and the host reserves none. Its mask is the union of the visible toast cards, so a click between toasts reaches what is below.
- The copy is built in the context of the file that declares the component, so it reads the plugin's state through that file's ids. The plugin's instance owns the state; the host owns the surfaces and their copies.
- A copy can outlive its instance for a moment: disabling a service deletes it with its slot, while the copies go on the event loop's next pass, as `scripts/smoke/rows/notifications.sh` read on 2026-09-28 through the log's diagnostics row. A copy's bindings on the instance check it for null, as `vgs.notifications`' stack does.
- A screen that is added gains a surface for every registration, and one that goes takes its surfaces with it. The disposer, or the instance's teardown, destroys every copy before the registration leaves, while the plugin that declared the component still exists.
- `vgsh ipc call shell lent` lists each registration under `layers` as its plugin and the screens it is built on.

## Invariants

1. A layer surface takes no keyboard focus, sits on the overlay layer and clears reserved space. Enforced by `scripts/smoke/rows/layers.sh`, which reads each surface's settings through the probe and its rectangle from the compositor's layer list.
2. A press outside the content's input passes through. Enforced by the same row, which clicks the fixture's pad, beside it, and beside it again with `inputAll` set, and counts the presses that reached the content.
3. Every surface of a registration goes with its disposer, its plugin's disable and its screen. Enforced by the same row, from the layer list, the fixture's record of its copies and the lending record.
