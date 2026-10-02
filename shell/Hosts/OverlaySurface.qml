import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

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
    property var releaseInputSurface: null
    readonly property var inputWindow: surface.contentItem.Window.window
    onInputWindowChanged: {
        if (releaseInputSurface !== null) releaseInputSurface();
        releaseInputSurface = Compositor.inputSurface(inputWindow);
    }
    Component.onDestruction: if (releaseInputSurface !== null) releaseInputSurface()

    readonly property var edges: edgesOf(placement)

    function lineageOf(item) {
        const items = [];
        while (item !== null) {
            items.push(item);
            item = item.parent;
        }
        return items;
    }

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
            id: inputPart
            required property Item modelData
            property int geometryRevision: 0
            readonly property var lineage: surface.lineageOf(modelData)
            readonly property rect rectangle: {
                const revision = geometryRevision;
                return modelData === null ? Qt.rect(0, 0, 0, 0) : surface.itemRect(modelData);
            }
            onLineageChanged: geometryRevision++
            x: Math.trunc(rectangle.x)
            y: Math.trunc(rectangle.y)
            width: Math.ceil(rectangle.width)
            height: Math.ceil(rectangle.height)

            // Region.item in 0.3.1 observes only the item's local geometry.
            // Parent layout, scrolling and remapping also move its mask.
            property QtObject geometryWatch: Instantiator {
                model: inputPart.lineage
                delegate: Connections {
                    required property Item modelData
                    target: modelData
                    function onXChanged() { inputPart.geometryRevision++; }
                    function onYChanged() { inputPart.geometryRevision++; }
                    function onWidthChanged() { inputPart.geometryRevision++; }
                    function onHeightChanged() { inputPart.geometryRevision++; }
                }
            }
        }
    }
}
