import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Ui
import "ImageTextLogic.js" as Logic

// StyledText with local images inline, such as a chat's custom emoji:
// `segments` is a list of { markup } runs of StyledText the caller has
// made safe and { image, alt } images, a file URL and the plain text drawn
// in its place. Each image draws as a square the height of a line of
// `font`, the font's own line height rounded down, aligned to the line's
// middle, so a line with an image keeps the pitch of one without.
//
// Text with no image draws as a plain Text with Qt's own right elision.
// Text with images elides itself: Qt's multi-line elision draws an image
// from an earlier line over the elided line's text
// (docs/architecture/runtime-qml.md). The cut keeps the longest run of
// whole words and whole images that fits `maximumLineCount` lines with one
// ellipsis after it, measured on a hidden copy of the text, so an image is
// never split.
//
// Every image loads through ImagePool, which puts an asynchronous load in
// Qt's pixmap cache before the text names the image, so no image decodes
// on the GUI thread. An image whose load fails draws its alt text.
Item {
    id: root

    property var segments: []
    property font font: Qt.font({ family: Theme.text.body.family, pixelSize: Theme.text.body.size, weight: Theme.text.body.weight })
    property color color: Theme.text.body.color
    property int maximumLineCount: 1
    property int wrapMode: Text.WordWrap
    // Whether the text drawn is cut short, and the lines it draws.
    readonly property bool truncated: imageMode ? cutShort : drawn.truncated
    readonly property int lineCount: drawn.lineCount
    // The side of an image in pixels, and in device pixels.
    readonly property int imageSize: Math.floor(metrics.height)
    readonly property int deviceSize: Math.round(imageSize * Screen.devicePixelRatio)

    // url -> the pool's image, for every image the text names; the URLs
    // among them that failed, drawn as their alt text; whether the text
    // holds an image and elides itself, and whether it was cut.
    property var held: ({})
    property var failed: []
    property bool imageMode: false
    property bool cutShort: false
    property bool ready: false

    implicitWidth: drawn.implicitWidth
    implicitHeight: drawn.implicitHeight

    onSegmentsChanged: rebuild()
    onFontChanged: rebuild()
    onWidthChanged: if (imageMode) rebuild()
    onMaximumLineCountChanged: rebuild()
    onWrapModeChanged: rebuild()
    onDeviceSizeChanged: rebuild()
    Component.onCompleted: {
        ready = true;
        rebuild();
    }
    Component.onDestruction: {
        for (const url of Object.keys(held)) {
            held[url].statusChanged.disconnect(root.imageStatusChanged);
            ImagePool.release(held[url]);
        }
        held = ({});
    }

    // A held image finished: a failure draws its alt text. A loaded image
    // needs nothing, since the text waited on the same load.
    function imageStatusChanged() {
        for (const url of Object.keys(held))
            if (held[url].status === Image.Error && failed.indexOf(url) === -1) {
                rebuild();
                return;
            }
    }

    // In order: acquire every image, give the measurer its text, give the
    // drawn text its text, then release the images neither names.
    function rebuild() {
        if (!ready) return;
        const next = {};
        for (const url of Logic.imageUrls(segments)) {
            const kept = held[url];
            if (kept !== undefined && kept.sourceSize.width === deviceSize) {
                next[url] = kept;
                continue;
            }
            const image = ImagePool.acquire(url, deviceSize);
            if (image === null) continue;
            image.statusChanged.connect(root.imageStatusChanged);
            next[url] = image;
        }
        const failing = Object.keys(next).filter(url => next[url].status === Image.Error);
        const tokens = Logic.tokens(segments, imageSize, failing.concat(Logic.imageUrls(segments).filter(url => next[url] === undefined)));
        imageMode = Logic.hasImage(tokens);
        if (imageMode) {
            drawn.elide = Text.ElideNone;
            const result = width > 0 ? Logic.elide(tokens, markup => {
                measurer.text = markup;
                return !measurer.truncated;
            }) : { markup: Logic.join(tokens, tokens.length), cut: false };
            measurer.text = result.markup;
            drawn.text = result.markup;
            cutShort = result.cut;
        } else {
            measurer.text = "";
            drawn.elide = Text.ElideRight;
            drawn.text = Logic.join(tokens, tokens.length);
            cutShort = false;
        }
        for (const url of Object.keys(held)) {
            if (next[url] === held[url]) continue;
            held[url].statusChanged.disconnect(root.imageStatusChanged);
            ImagePool.release(held[url]);
        }
        held = next;
        failed = failing;
    }

    FontMetrics {
        id: metrics
        font: root.font
    }

    Text {
        id: measurer
        visible: false
        width: root.width
        textFormat: Text.StyledText
        font: root.font
        wrapMode: root.wrapMode
        maximumLineCount: root.maximumLineCount
        elide: Text.ElideNone
    }

    Text {
        id: drawn
        width: root.width
        textFormat: Text.StyledText
        font: root.font
        color: root.color
        wrapMode: root.wrapMode
        maximumLineCount: root.maximumLineCount
    }
}
