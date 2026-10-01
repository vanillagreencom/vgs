# D067: Full-screen overlays capture keyboard input through a Hyprland submap

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-596
**Refines**: [D028](D028-one-generated-hyprland-layer.md)
**API Contract**: Overlay entries may implement `navigate(direction)`, where direction is `left`, `right`, `up` or `down`. Only the frontmost overlay receives a navigation key; if it has no `navigate`, the key is ignored.
**Refined by**: [D068](D068-keyboard-first-standard.md)

**Context**: A full-screen overlay can hold Quickshell keyboard focus, but Hyprland runs global binds before the focused layer sees the key. A user's `movefocus` keys can therefore move focus behind the browser instead of moving the browser carousel. Hyprland v0.56.2 reports Lua binds through `hyprctl binds -j` as dispatcher `__lua` with an opaque registry index, so the generated layer cannot learn focus keys by reading binds back.

**Decision**: The generated Hyprland layer owns one capture submap for unanchored `overlay` surfaces. While any mapped layer with namespace `vgs:overlay` exists, the layer enters that submap. When none remain, it resets only if the current submap is the capture submap. The submap includes each enabled plugin shortcut again, so shell shortcuts keep working while an overlay is open. The layer wraps `hl.dsp.focus` and `hl.bind` once. A focus dispatcher built from a `direction` field is recorded in a weak table. A later default-map bind using that dispatcher is also bound inside the capture submap to a core global shortcut for that direction. The core registers the directional global shortcuts and forwards them only to the frontmost overlay instance. An overlay without `navigate(direction)` ignores the key and keeps older overlays behind it from receiving the key.

**Rationale**:
- Hyprland owns bind precedence, so capture must start in Hyprland before a background bind fires.
- The layer loads first in `hyprland.lua`, so a wrapper can learn the user's focus binds while their own Lua still stays the source of truth.
- A submap blocks default-map user binds. Exclusive keyboard focus sends unbound text to the overlay instead of a background client.
- `hl.get_layers()` makes normal close stateless across more than one open overlay. A shell crash unmaps the layer, and the generated Hyprland close hook resets the active submap.
- Plugin shortcuts are repeated in the capture submap, so `SUPER+T`, `SUPER+W` and other VGS shortcuts still reach the shell while the browser or launcher is open.
- A bind to a Lua function that calls focus is not learned. The layer only sees dispatcher objects it builds through `hl.dsp.focus`.

## Omarchy comparison

Omarchy's image picker keeps the keyboard model inside its layer surface. It uses Left, Right, Tab, Shift+Tab, Enter, Escape and type-to-filter in the picker. It does not need to learn arbitrary user focus binds because Omarchy owns its default Hyprland configuration. VGS follows Omarchy's overlay-level keyboard ownership and differs at the compositor layer because VGS is loaded into a user-owned Hyprland Lua file.

**Revisit When**: Hyprland exposes Lua dispatcher details through a stable API, or submaps stop blocking default-map binds before a focused layer sees keys.

**Verification**: `scripts/test-hyprland-layer.js` pins the capture submap, wrapper, plugin bind copy and layer event hooks with controls. `scripts/test-plugin-logic.js` pins the surface keyboard decision with controls. `scripts/smoke/rows/theme-browser.sh`, read on 2026-09-29, opens the nested browser and verifies the learned focus keys move its carousel, Tab switches the browser tabs, Alt+I switches the theme browser scope and every shown non-refused theme card with a visible built `ThemeCard` carries a visible palette strip with drawn swatches; its controls remove the theme toggle key and change one built card's `ThemeCard` from `palette: root.colors` to `palette: root.modelData.name === "<card>" ? null : root.colors`. `scripts/smoke/rows/overlay-capture.sh`, read on 2026-09-29, appends user binds to the nested Hyprland Lua and verifies the exec bind is blocked while the browser is open, unbound typing does not reach a mapped helper toplevel, the exec bind stays blocked after another overlay closes while the browser remains open, fires after close, and fires after the shell's recorded Quickshell pid is killed; its controls remove submap entry, replace the close handler with `local _ = layer` and read the stuck submap after SIGKILL, make the close handler reset unconditionally and disable the `hl.bind` wrapper. Its `WlrKeyboardFocus.OnDemand` copy did not redden the typing check on 2026-09-29 because Hyprland kept the browser as the key target while `vgs:capture` was active.

**References**: [D028](D028-one-generated-hyprland-layer.md), [hyprland.md](../architecture/hyprland.md), [runtime.md](../architecture/runtime.md), [runtime-hyprland-capture.md](../architecture/runtime-hyprland-capture.md), [surfaces.md](../architecture/surfaces.md), [theme-overlay.md](../architecture/theme-overlay.md)
