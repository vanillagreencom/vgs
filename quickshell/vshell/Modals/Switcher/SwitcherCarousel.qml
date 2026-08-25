pragma ComponentBehavior: Bound

import QtQuick
import qs.Common

// The switcher's carousel: a rail of leaning slices with the selection opened
// out to a full preview in the middle, everything else compressed to a sliver
// and overlapping its neighbour. Ported from the Omarchy 4 image picker, whose
// proportions are reproduced here rather than reinvented.
//
//    ╱╱╱╱╱╱╱  ┌───────────────────────┐  ╱╱╱╱╱╱╱
//   ╱╱╱╱╱╱╱   │      selected         │   ╱╱╱╱╱╱╱
//  ╱╱╱╱╱╱╱    │      full preview     │    ╱╱╱╱╱╱╱
//   ╱╱╱╱╱╱╱   └───────────────────────┘   ╱╱╱╱╱╱╱
//   dimmed slivers          ^              dimmed slivers
//                    z above its neighbours
//
// The base proportions are Omarchy's in logical pixels, which fill a 1920-wide
// screen exactly. `unit` grows them together on anything wider, so the rail
// keeps its shape instead of sitting as a small island on a HiDPI panel.
//
// Nothing here animates, also on purpose: a page step lands instantly, the way
// flicking through a stack of prints does. Sliding fifteen masked layers per
// keypress would cost far more than it reads.
Item {
    id: carousel

    // Filtered entries, in display order: [{image, label, key}]
    property var items: []
    property int selectedIndex: 0
    property real dpr: 1

    signal picked(int index)
    signal activated

    readonly property real baseRailWidth: 768 + 13 * 78 + 40
    // NOT named `scale`: that is Item's own transform property, and shadowing
    // it would magnify the whole rail instead of sizing it.
    readonly property real unit: {
        const byWidth = carousel.width / carousel.baseRailWidth;
        const byHeight = carousel.height / 475;
        return Math.max(0.35, Math.min(2, Math.min(byWidth, byHeight)));
    }

    readonly property real expandedWidth: 768 * unit
    readonly property real expandedHeight: 475 * unit
    readonly property real sliceWidth: 108 * unit
    readonly property real sliceHeight: 432 * unit
    // Negative: consecutive slivers OVERLAP, which is what makes the rail read
    // as a stack rather than as a row of separate tiles.
    readonly property real sliceSpacing: -30 * unit
    readonly property real skewOffset: 28 * unit

    readonly property real itemStep: sliceWidth + sliceSpacing
    readonly property real railWidth: expandedWidth + 13 * itemStep
    readonly property real previewX: (railWidth - expandedWidth) / 2
    // Only what the rail can actually show is built. Omarchy keeps a fixed 16
    // per side; deriving it from the rail instead means a wide screen does not
    // hold a dozen decoded images that are positioned off the end of it.
    readonly property int slicesPerSide: Math.ceil(previewX / Math.max(1, itemStep)) + 1

    // Slivers decode to a fixed budget, NOT to their display size: a slice is a
    // tall narrow crop, so covering it from a 16:9 source needs a decode several
    // times its own width, and asking for that at HiDPI display size across a
    // whole rail is hundreds of megabytes. This is Omarchy's thumbnail size,
    // which is the same trade they make one step earlier by pre-rendering
    // 1536x864 thumbnails on disk. The selected slot decodes properly — see
    // SwitcherStage.
    readonly property int sliceDecodeWidth: 1536
    readonly property int sliceDecodeHeight: 864

    // Wallpaper filenames are user data and routinely carry spaces, '#' and '%',
    // all of which break a raw file:// URL. Encode per segment, as CachingImage
    // does, so the separators survive. `Paths.toFileUrl` deliberately does not:
    // it is the raw-prefix helper.
    function fileUrl(path) {
        if (!path)
            return "";
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
    }

    function urlFor(index) {
        const entry = (carousel.items || [])[index];
        return entry ? carousel.fileUrl(entry.image) : "";
    }

    // Slivers read a pre-sized thumbnail; the SELECTED slot never does, so the
    // one image shown at full size still decodes from the original and its
    // quality is untouched. Empty `thumb` falls back to the source, which is
    // what the rail read before the cache existed, so a cold or unwritable
    // cache costs speed and nothing else.
    function thumbUrlFor(index) {
        const entry = (carousel.items || [])[index];
        if (!entry)
            return "";
        return carousel.fileUrl(entry.thumb || entry.image);
    }

    // The image `delta` steps away, for the selected slot's lookahead.
    function neighborUrl(delta) {
        const count = (carousel.items || []).length;
        if (count < 2)
            return "";
        return carousel.urlFor(((carousel.selectedIndex + delta) % count + count) % count);
    }

    Item {
        id: rail
        width: carousel.railWidth
        height: carousel.expandedHeight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
            model: (carousel.items || []).length

            SwitcherSlice {
                id: slice

                required property int index

                readonly property int relativeIndex: index - carousel.selectedIndex
                readonly property bool isSelected: index === carousel.selectedIndex
                readonly property bool nearby: Math.abs(relativeIndex) <= carousel.slicesPerSide
                // A small hysteresis band around the visible window: the source
                // is kept a couple of steps past the edge so paging back and
                // forth over the same entries does not re-decode, and RELEASED
                // beyond that. Latching it on for good instead — which is what
                // Omarchy does, over a list of a dozen — retained every sliver
                // a long browse had ever passed: 79 installed themes is 79
                // decoded pixmaps, not the bound this file claims.
                readonly property bool retained: Math.abs(relativeIndex) <= carousel.slicesPerSide + 2

                visible: nearby
                x: {
                    if (isSelected)
                        return carousel.previewX;
                    if (relativeIndex < 0)
                        return carousel.previewX + relativeIndex * carousel.itemStep;
                    return carousel.previewX + carousel.expandedWidth + carousel.sliceSpacing + (relativeIndex - 1) * carousel.itemStep;
                }
                y: isSelected ? 0 : (carousel.expandedHeight - carousel.sliceHeight) / 2
                width: isSelected ? carousel.expandedWidth : carousel.sliceWidth
                height: isSelected ? carousel.expandedHeight : carousel.sliceHeight
                z: isSelected ? 100 : 50 - Math.min(Math.abs(relativeIndex), 40)

                selected: isSelected
                skewOffset: carousel.skewOffset
                dimColor: Theme.background
                borderColor: isSelected ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.28)
                borderWidth: isSelected ? 3 : 1
                onClicked: isSelected ? carousel.activated() : carousel.picked(index)

                // The selected slot decodes at display size and warms its
                // neighbours; the slivers share one small budget. Two separate
                // cache keys on purpose — see SwitcherStage.
                SwitcherStage {
                    anchors.fill: parent
                    visible: slice.isSelected
                    dpr: carousel.dpr
                    imageSource: slice.isSelected ? carousel.urlFor(slice.index) : ""
                    prefetchSources: slice.isSelected ? [carousel.neighborUrl(-1), carousel.neighborUrl(1)] : []
                }

                Image {
                    anchors.fill: parent
                    visible: !slice.isSelected
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: carousel.sliceDecodeWidth
                    sourceSize.height: carousel.sliceDecodeHeight
                    source: slice.retained ? carousel.thumbUrlFor(slice.index) : ""
                }
            }
        }
    }
}
