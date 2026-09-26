pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// Selected carousel preview with loading/error states and adjacent-image lookahead.
Item {
    id: stage

    property real dpr: 1
    property string imageSource: ""
    // Hold decoded previous and next entries for paging. Bound references so browsing cannot retain every full-size image.
    property var prefetchSources: []

    // Cap decode size for large wallpapers. Lookahead and the visible Image must share all pixmap-cache inputs.
    // fillMode affects the cache key as well as sourceSize; mismatches decode twice despite preloading.
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
