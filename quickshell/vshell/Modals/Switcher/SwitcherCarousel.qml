pragma ComponentBehavior: Bound

import QtQuick
import qs.Common

// Carousel geometry follows the Omarchy image picker: overlapping leaning slices surround a full selected preview.
// Scale base proportions together and keep page changes immediate.
Item {
    id: carousel

    // Filtered entries, in display order: [{image, label, key}]
    property var items: []
    property int selectedIndex: 0
    property real dpr: 1

    signal picked(int index)
    signal activated

    readonly property real baseRailWidth: 768 + 13 * 78 + 40
    // Avoid scale: Item owns that transform property, which would magnify the rail instead of sizing its geometry.
    readonly property real unit: {
        const byWidth = carousel.width / carousel.baseRailWidth;
        const byHeight = carousel.height / 475;
        return Math.max(0.35, Math.min(2, Math.min(byWidth, byHeight)));
    }

    readonly property real expandedWidth: 768 * unit
    readonly property real expandedHeight: 475 * unit
    readonly property real sliceWidth: 108 * unit
    readonly property real sliceHeight: 432 * unit
    // Negative spacing lets adjacent slices overlap.
    readonly property real sliceSpacing: -30 * unit
    readonly property real skewOffset: 28 * unit

    readonly property real itemStep: sliceWidth + sliceSpacing
    readonly property real railWidth: expandedWidth + 13 * itemStep
    readonly property real previewX: (railWidth - expandedWidth) / 2
    // Build only the slices that the rail can display to limit decoded images.
    readonly property int slicesPerSide: Math.ceil(previewX / Math.max(1, itemStep)) + 1

    // Cap slice decoding independently of display size; tall narrow crops would otherwise decode large images across the rail.
    // The selected slot uses its own display-size budget.
    readonly property int sliceDecodeWidth: 1536
    readonly property int sliceDecodeHeight: 864

    // Encode file-path segments so spaces, # and % remain valid without encoding directory separators. Paths.toFileUrl does not encode; do not substitute it.
    function fileUrl(path) {
        if (!path)
            return "";
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
    }

    function urlFor(index) {
        const entry = (carousel.items || [])[index];
        return entry ? carousel.fileUrl(entry.image) : "";
    }

    // Use cached thumbnails for slices. The selected slot reads the original; missing thumbnails fall back to the source.
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
                // Retain sources just beyond the visible range to avoid repeated decoding during short back-and-forth paging.
                // Release them farther away so a long browse cannot retain every image.
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

                // Keep separate cache sizes for slices and the selected slot; selected lookahead uses the selected slot's cache key.
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
