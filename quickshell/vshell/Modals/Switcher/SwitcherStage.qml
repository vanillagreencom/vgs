pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// The carousel's selected slot: the one image shown at full size, its
// lookahead, and the two states that are not an image (loading, undecodable).
// Split out of SwitcherCarousel.qml, which owns the geometry, and out of
// FullScreenSwitcher.qml, which owns paging and keys.
Item {
    id: stage

    property real dpr: 1
    property string imageSource: ""
    // Adjacent entries, kept decoded so a page step is a cache hit. Bounded to
    // prev/current/next on purpose: Qt retains only ~2 MB of UNreferenced
    // pixmaps, so residency is the elements that hold a reference rather than
    // the whole set — gruvy-glass alone ships 38 wallpapers.
    property var prefetchSources: []

    // Decode at display size, capped: theme previews are 1920x1080 but a user
    // wallpaper can be far larger than the screen, and on a HiDPI panel the
    // display size alone would ask for a decode bigger than any source we
    // actually ship.
    //
    // The lookahead MUST match the visible Image on EVERY property the pixmap
    // cache keys on — url, sourceSize, fillMode, sourceClipRect, frame, mirror —
    // not just the size. QQuickImage folds fillMode into the key through
    // QQuickImageProviderOptions::preserveAspectRatioFit, so a delegate left at
    // the default Image.Stretch decodes under a DIFFERENT key and the page step
    // misses exactly the entry the lookahead warmed: it pays the memory and
    // re-decodes anyway. These three are declared once here and bound by both
    // so the two cannot drift apart.
    readonly property int decodeCap: 2560
    readonly property int decodeWidth: Math.min(stage.decodeCap, Math.max(1, Math.round(stage.width * stage.dpr)))
    readonly property int decodeHeight: Math.min(stage.decodeCap, Math.max(1, Math.round(stage.height * stage.dpr)))
    // Crop, not fit: the tile is a fixed parallelogram and a letterboxed image
    // inside it would put bars where the lean is supposed to be.
    readonly property int decodeFillMode: Image.PreserveAspectCrop

    Image {
        id: preview
        anchors.fill: parent
        visible: status === Image.Ready
        asynchronous: true
        cache: true
        fillMode: stage.decodeFillMode
        sourceSize.width: stage.decodeWidth
        sourceSize.height: stage.decodeHeight
        source: stage.imageSource
    }

    Repeater {
        model: stage.prefetchSources

        Image {
            required property string modelData
            visible: false
            asynchronous: true
            cache: true
            fillMode: stage.decodeFillMode
            sourceSize.width: stage.decodeWidth
            sourceSize.height: stage.decodeHeight
            source: modelData
        }
    }

    VgsSpinner {
        anchors.centerIn: parent
        visible: preview.status === Image.Loading
    }

    StyledText {
        anchors.centerIn: parent
        visible: preview.status !== Image.Ready && preview.status !== Image.Loading
        text: I18n.tr("Preview unavailable")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceText
        style: Text.Outline
        styleColor: Theme.withAlpha(Theme.background, 0.7)
    }
}
