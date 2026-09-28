# D026: A passive layer is a capability that draws a plugin's component on every screen

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: VGS-476

**Refines**: [D005](D005-kinds-are-surfaces-no-dependencies.md), [D012](D012-core-owns-lent-objects.md)

**Context**: The `vgs.notifications` plugin draws a stack of cards on every screen, over every window, and its inbox over that stack, while the user keeps typing into the focused application. A plugin may not create a window: `scripts/check-plugin-boundary.py` refuses one as `surface-type`. The summonable kinds cannot carry the stack. An overlay covers its screen and takes the keyboard on demand, a panel sits at one placement, and `SummonHost` builds each on summon and destroys it on hide, so its lifetime is the summon's rather than the service's. The core toast stack draws each toast as the core's themed card, on one screen.

**Decision**: Add a capability, `layers`, not a kind. `shell.layers.show(component)` hands the core a `Component` the plugin declares and answers a disposer. `shell/Core/Layers.qml` holds the registration. `shell/Hosts/LayerHost.qml` builds one surface per screen for it, with one copy of the component inside. The surface is anchored on every edge, sits on the overlay layer, respects reserved space, reserves none, and never takes keyboard focus. Pointer input reaches it only where the content's `inputAll` or `inputItem` says. The core assigns each copy its `screen`. The disposer, or the instance's teardown, destroys every copy.

**Rationale**:

- The state lives in the plugin's service, and a layer is only its view on every screen. A capability keeps that one owner. A per-screen kind, as `background` is, builds one instance of the plugin on each screen, each with state of its own to reconcile.
- A surface that never takes the keyboard cannot steal a keystroke, so it can show while the user types. The input region lets a press through everywhere the content does not ask for it.
- The surface covers its screen at a fixed size, so adding or removing a card changes only the content and never the surface's size. Respecting reserved space places it below the bar without reading the bar.
- The copy is built in the context of the file that declares the component, so the plugin reads its state through that file's ids and needs no API to hand the view its state.
- The core lends the surface and releases it with the instance, as it does every lent object.

**Revisit When**: A layer needs keyboard focus, one screen rather than every screen, or a layer other than overlay.

**Verification**: `scripts/smoke/rows/layers.sh` runs against the `acme.layers` fixture. It reads each surface's layer, keyboard mode, exclusion and rectangle, clicks on the content's input, beside it and with `inputAll` set, adds and removes a monitor, refuses a value that is not a component and a content without `screen`, and releases the registration through its disposer and a disable.

**References**: [D003](D003-everything-is-a-plugin.md), [D005](D005-kinds-are-surfaces-no-dependencies.md), [D012](D012-core-owns-lent-objects.md), [layers.md](../architecture/layers.md)
