# D058: A passive layer takes input on the union of its items

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: VGS-619
**Refines**: [D026](D026-passive-layers-are-a-capability.md)

**Context**: A passive layer can have separate controls with non-interactive text and gaps between them. One bounding rectangle would take input from the application below those gaps. The Jarvis plan assigns this core contract to J06 before its bubble is implemented.

**Decision**: A layer copy declares `inputItems`, an array of Items in its own tree. The surface takes pointer input on the union of their rectangles. An absent or empty list passes all input through. `inputAll` still gives the whole surface input. `LayerHost` uses the existing `OverlaySurface`, which owns the Region union through its Instantiator. Registrations and their per-screen copies keep their existing owners and lifetime.

**Rationale**:
- The existing core notice surface already owns the required union. Reusing it keeps one mask mechanism for core notices and passive plugin content.
- Several independent rectangles leave the gaps to the application below. A bounding rectangle does not.
- The notifications plugin keeps its current behavior by declaring `[column]`. The contract has no singular-property compatibility path.
- Omarchy's current reference, basecamp/omarchy `8b4eae66da2938ba9559f103b18dbf85cdf28a70`, uses `Region { item: popupColumn }` in `shell/plugins/notifications/Service.qml`, and an empty region for the visual-only `shell/plugins/osd/Osd.qml`. VGS keeps the same masked, keyboard-free layer approach. It differs by accepting separate item rectangles and letting the compositor subtract reserved space instead of calculating bar clearance.

**Revisit When**: A layer needs non-rectangular input or input from an item outside its copy's tree.

**Verification**: `scripts/smoke/rows/layers.sh` reads press and release at each pad and from a real xdg client below their gap. It exercises empty input, item removal and restoration, `inputAll`, disposer, disable and monitor changes. Its controls omit either region, catch the gap, drop the host's item binding and hide client button records. Each breaks the shared input assertion.

**References**: [layers.md](../architecture/layers.md), [Jarvis plan § Bubble and orb](../plans/v2-jarvis-plan.md#43-bubble-and-orb), [Quickshell 0.3.1 Region](https://quickshell.org/docs/v0.3.1/types/Quickshell/Region/), [Quickshell 0.3.1 QsWindow mask](https://quickshell.org/docs/v0.3.1/types/Quickshell/QsWindow/)
