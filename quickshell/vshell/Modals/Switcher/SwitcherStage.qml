pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// The switcher's preview area: one large image, its lookahead, and the three
// states that are not an image (loading, empty/unreadable, undecodable).
// Split out of FullScreenSwitcher.qml, which owns paging and keys.
Item {
    id: stage

    property real dpr: 1
    property bool hasItems: false
    property string emptyText: ""
    property string imageSource: ""
    // Adjacent entries, kept decoded so a page step is a cache hit. Bounded to
    // prev/current/next on purpose: Qt retains only ~2 MB of UNreferenced
    // pixmaps, so residency is the elements that hold a reference (~25 MB at
    // 1920x1080) rather than the whole set — gruvy-glass alone ships 38.
    property var prefetchSources: []

    // Decode at display size: theme previews are 1920x1080 but a user wallpaper
    // can be far larger than the screen.
    //
    // The lookahead MUST match the visible Image on EVERY property the pixmap
    // cache keys on — url, sourceSize, fillMode, sourceClipRect, frame, mirror —
    // not just the size. QQuickImage folds fillMode into the key through
    // QQuickImageProviderOptions::preserveAspectRatioFit, so a delegate left at
    // the default Image.Stretch decodes under a DIFFERENT key and the page step
    // misses exactly the entry the lookahead warmed: it pays the memory and
    // re-decodes anyway. These three are declared once here and bound by both
    // so the two cannot drift apart.
    readonly property int decodeWidth: Math.max(1, Math.round(stage.width * stage.dpr))
    readonly property int decodeHeight: Math.max(1, Math.round(stage.height * stage.dpr))
    readonly property int decodeFillMode: Image.PreserveAspectFit

    Image {
        id: preview
        anchors.fill: parent
        visible: stage.hasItems && status === Image.Ready
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
        visible: stage.hasItems && preview.status === Image.Loading
    }

    StyledText {
        anchors.centerIn: parent
        width: Math.min(parent.width, 720)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: !stage.hasItems
        text: stage.emptyText
        font.pixelSize: Theme.fontSizeLarge
        color: Theme.surfaceVariantText
    }

    StyledText {
        anchors.centerIn: parent
        visible: stage.hasItems && preview.status !== Image.Ready && preview.status !== Image.Loading
        text: I18n.tr("Preview unavailable")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }
}
