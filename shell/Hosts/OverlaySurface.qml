import QtQuick
import Quickshell
import Quickshell.Wayland

// The layer window for passive plugin content and core notices, on the
// overlay layer. The compositor keeps it in the area other layers leave
// free, such as the screen less the bar, and it
// reserves none. `inset` is the gap on every anchored edge.
//
// `placement` is `center` or one corner: `top-left`, `top-right`,
// `bottom-left` or `bottom-right`. A corner anchors its two edges and the
// host sizes the surface; `center` anchors all four edges, so the surface
// fills the free area less the inset and the host centres its content.
//
// Pointer input reaches the surface only on `inputItems`: the mask is the
// union of their rectangles, and with none every press passes through to
// what is below. `inputAll` instead lets the whole surface take input.
PanelWindow {
    id: surface

    required property string placement
    required property int inset
    property var inputItems: []
    property bool inputAll: false

    readonly property var edges: edgesOf(placement)

    function edgesOf(placement) {
        switch (placement) {
        case "center": return { top: true, bottom: true, left: true, right: true };
        case "top-left": return { top: true, bottom: false, left: true, right: false };
        case "top-right": return { top: true, bottom: false, left: false, right: true };
        case "bottom-left": return { top: false, bottom: true, left: true, right: false };
        case "bottom-right": return { top: false, bottom: true, left: false, right: true };
        }
        throw new Error("OverlaySurface: placement=" + JSON.stringify(placement) + " is not center or a corner");
    }

    anchors { top: edges.top; bottom: edges.bottom; left: edges.left; right: edges.right }
    margins { top: inset; bottom: inset; left: inset; right: inset }
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    color: "transparent"
    mask: inputAll ? null : inputRegion
    WlrLayershell.layer: WlrLayer.Overlay

    Region {
        id: inputRegion
        regions: inputRegions.items
    }

    // REVISIT(D058): non-rectangular input needs more than an item's rectangle.
    Instantiator {
        id: inputRegions
        property var items: []
        model: surface.inputItems
        onObjectAdded: (index, object) => {
            const next = items.slice();
            next.splice(index, 0, object);
            items = next;
        }
        onObjectRemoved: (index, object) => {
            items = items.filter(item => item !== object);
        }
        delegate: Region {
            required property Item modelData
            item: modelData
        }
    }
}
