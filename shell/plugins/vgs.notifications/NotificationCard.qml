import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.Ui
import "NotificationLogic.js" as Logic

// One notification as a glass capsule: its image, the Lucide icon its
// x-vgs-icon hint names in the tone its x-vgs-tone hint names, or its
// application icon, its summary and its body, and the hover actions over
// its right end. A sender
// a NotificationLogic rule reads shows the people it names as faces in the
// icon's place, and the workspace it belongs to as that workspace's icon,
// when there is one, before the rule's title in place of the summary. It draws no fill of its
// own: the GlassSurface under it paints the glass and the slot drives its
// size, its content fade and its lifetime. It holds no notification
// object, only the values it draws.
Item {
    id: card

    required property var look
    property string app: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property string image: ""
    property string desktopEntry: ""
    // The VGS hint roles (NotificationLogic.readHints): a Lucide name and a
    // status tone, or "".
    property string hintIcon: ""
    property string hintTone: ""
    // The workspace the card belongs to: the one `enrichment` names, or the
    // one the service resolved for it (NotificationLogic.slackWorkspaceFor),
    // or "".
    property string workspace: ""
    // The file URL of that workspace's icon, or "".
    property string workspaceIcon: ""
    // One file URL per face, from the optional Slack token cache.
    property var faceImages: []
    // The custom emoji of the card's workspace, name -> file URL, or null
    // (NotificationLogic.slackEmojiFor).
    property var emoji: null
    // The slot fades the content during its morph. The content keeps its
    // full-size layout and stays centred while the card is narrower, so the
    // text never reflows.
    property real contentOpacity: 1
    // [{ id, label }] shown as pills at the right edge while `showActions`.
    property var actions: []
    property bool showActions: false
    readonly property bool hovered: hoverTracker.hovered
    readonly property real radius: look.radius.full
    signal actionTriggered(string id)
    signal closeRequested()
    signal cardClicked()

    readonly property real fullWidth: look.card.width
    // The content with `pad` all round. The content never outgrows
    // maxHeight less that pad: the body shows only the lines that fit.
    readonly property real fullHeight: content.implicitHeight + 2 * pad
    readonly property real pad: look.card.pad
    // The stack's text column: text without media starts this far in from
    // either end, and every text ends this far from the right end.
    required property real textColumn
    readonly property string iconSource: image.length > 0 ? image : iconPath(appIcon)
    readonly property string sanitizedBody: Logic.sanitizeBody(body, app, appIcon)
    // The body as ImageText segments: StyledText with every image tag
    // stripped (NotificationLogic.styledBody), and the workspace's custom
    // emoji as images (emojiSegments).
    readonly property var bodySegments: Logic.emojiSegments(Logic.styledBody(body, app, appIcon), emoji)
    readonly property bool singleLine: sanitizedBody.length === 0
    readonly property bool iconInSummary: singleLine && Logic.summaryStartsWithGlyph(summary)
    // NotificationLogic.enrich's reading of this sender, or null.
    readonly property var enrichment: Logic.enrich(app, desktopEntry, appIcon, summary, body)
    readonly property bool showsFaces: enrichment !== null && enrichment.faces.length > 0
    readonly property bool showsBadge: enrichment !== null && workspace.length > 0 && workspaceIcon.length > 0 && badgeImage.status === Image.Ready
    // What the media slot draws: the people the rule read, else the
    // notification's image, else the Lucide icon its x-vgs-icon hint names,
    // else its application's icon; none when the one-line summary opens
    // with its own icon glyph. A hint name the Lucide set lacks draws no
    // media, and Icon logs it.
    readonly property string mediaKind: showsFaces ? "faces" : iconInSummary ? "" : image.length > 0 ? "thumbnail" : hintIcon.length > 0 ? "glyph" : iconSource.length > 0 ? "icon" : ""
    readonly property bool showsSlot: mediaKind !== "" && mediaSlot.drawable
    // The lines the text runs to at the compact tier's width, which no
    // tier changes, so the tier the judge reads from it moves no line: a
    // summary that fits that width is one line, a longer one or one with a
    // line break two, and a body adds at least one.
    readonly property real compactTitleWidth: fullWidth - pad - look.media.compact.size - look.card.gapIcon - textColumn - (showsBadge ? look.badge.size + look.badge.gap : 0)
    readonly property int compactLines: (summaryRow.visible ? (title.indexOf("\n") === -1 && titleMeasure.advanceWidth <= compactTitleWidth ? 1 : 2) : 0) + (singleLine ? 0 : 1)
    readonly property string mediaTier: Logic.mediaTier(compactLines)
    readonly property real contentLeftInset: showsSlot ? pad : textColumn
    readonly property real contentWidth: Math.max(0, fullWidth - contentLeftInset - textColumn)
    readonly property real contentOffset: contentLeftInset - (fullWidth - contentWidth) / 2
    readonly property real slotLeft: showsSlot ? content.x + mediaSlot.x : -1
    // The summary as drawn: the rule's title once the workspace's icon
    // stands in for the workspace.
    readonly property string title: showsBadge ? enrichment.title : summary

    // An icon value as an image source: a URL as it is, a path as a file
    // URL, a themed name through the icon theme, and nothing for a name the
    // theme lacks, so no placeholder is drawn.
    function iconPath(icon) {
        const value = String(icon || "");
        if (value.length === 0) return "";
        if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value;
        if (value.charAt(0) === "/") return "file://" + value;
        return Quickshell.iconPath(value, true);
    }

    implicitWidth: fullWidth
    implicitHeight: fullHeight
    clip: true

    HoverHandler { id: hoverTracker }

    MouseArea {
        anchors.fill: parent
        PointerCursor {}
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) card.closeRequested();
            else card.cardClicked();
        }
    }

    RowLayout {
        id: content
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: card.contentOffset
        width: card.contentWidth
        opacity: card.contentOpacity
        spacing: card.showsSlot ? card.look.card.gapIcon : 0

        MediaSlot {
            id: mediaSlot
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight
            Layout.alignment: Qt.AlignVCenter
            visible: card.showsSlot
            look: card.look
            tier: card.mediaTier
            kind: card.mediaKind
            source: card.iconSource
            names: card.showsFaces ? card.enrichment.faces : []
            more: card.showsFaces ? card.enrichment.more : 0
            images: card.showsFaces ? card.faceImages : []
            carried: card.image
            glyph: card.hintIcon
            glyphColor: card.hintTone === "" ? card.look.text.foreground : card.look.tone[card.hintTone]
        }

        ColumnLayout {
            id: textBlock
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: card.look.card.lineGap

            RowLayout {
                id: summaryRow
                Layout.fillWidth: true
                visible: card.summary.length > 0
                spacing: card.showsBadge ? card.look.badge.gap : 0

                // The workspace's icon, level with the summary's first line.
                // Its image loads while hidden, and the name gives way to it
                // only once it has.
                ClippingRectangle {
                    objectName: "notificationBadge"
                    Layout.preferredWidth: card.showsBadge ? card.look.badge.size : 0
                    Layout.preferredHeight: card.look.badge.size
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Math.max(0, (titleMetrics.height - card.look.badge.size) / 2)
                    visible: card.showsBadge
                    radius: card.look.badge.radius
                    color: card.look.badge.fill

                    Image {
                        id: badgeImage
                        anchors.fill: parent
                        source: card.enrichment !== null && card.workspace.length > 0 ? card.workspaceIcon : ""
                        // The helper rewrites the same file when it reads
                        // the workspace list again.
                        cache: false
                        sourceSize.width: card.look.badge.size * Screen.devicePixelRatio
                        sourceSize.height: card.look.badge.size * Screen.devicePixelRatio
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                }

                Text {
                    id: titleText
                    objectName: "notificationTitleText"
                    // The specification makes the summary one line of plain
                    // text, so it is never read as markup.
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: card.title
                    color: card.look.text.foreground
                    font.family: card.look.font.family
                    font.pixelSize: card.look.text.title.size
                    font.weight: card.look.text.title.weight
                    style: Text.Raised
                    styleColor: card.look.text.summaryShadow
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                    maximumLineCount: card.look.card.summaryLines
                }

                FontMetrics {
                    id: titleMetrics
                    font: titleText.font
                }

                TextMetrics {
                    id: titleMeasure
                    font: titleText.font
                    text: card.title
                }
            }

            ImageText {
                id: bodyText
                objectName: "notificationBodyText"
                // The height left for the body under maxHeight, and so the
                // whole lines it shows; the last one elides.
                readonly property real room: card.look.card.maxHeight - 2 * card.pad - Layout.topMargin - (summaryRow.visible ? summaryRow.implicitHeight + textBlock.spacing : 0)
                Layout.fillWidth: true
                Layout.topMargin: card.look.card.lineGap
                visible: !card.singleLine
                // StyledText, since the server advertises body markup. The
                // body's fade is its colour's alpha, so an emoji draws at
                // full strength.
                segments: card.bodySegments
                color: card.look.text.subtitle.color
                font: Qt.font({ family: card.look.font.family, pixelSize: card.look.text.subtitle.size })
                maximumLineCount: Math.max(1, Math.floor(room / bodyMetrics.height))
            }

            FontMetrics {
                id: bodyMetrics
                font: bodyText.font
            }
        }
    }

    // The fade of the glass under the hover actions keeps the text from
    // colliding with them. It starts and ramps where the reference's did,
    // then holds its full alpha out to the capsule's own right end, rounded
    // to that end, so nothing draws past the glass's curve; the card's clip
    // is only its bounding box. It stays put while the pills slide in.
    Rectangle {
        id: trayFade
        readonly property real ramp: card.look.tray.fadeStop * (tray.width + card.look.tray.fadeReach)
        x: tray.x - (card.look.tray.fadeReach - card.look.tray.fadeOverhang)
        width: card.width - x
        height: card.height
        topRightRadius: Math.min(card.radius, height / 2)
        bottomRightRadius: topRightRadius
        visible: tray.visible
        opacity: tray.opacity
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: card.look.tray.fadeStart }
            GradientStop { position: Math.min(1, trayFade.ramp / Math.max(1, trayFade.width)); color: card.look.tray.fadeEnd }
        }
    }

    // The hover actions float over the right end of the text, the card's pad
    // in from its end as the text is from its start.
    Item {
        id: tray
        anchors.right: parent.right
        anchors.rightMargin: card.pad
        anchors.verticalCenter: parent.verticalCenter
        width: actionRow.width
        height: actionRow.height
        visible: opacity > 0
        opacity: card.showActions && card.actions.length > 0 && card.contentOpacity >= 1 ? 1 : 0
        Behavior on opacity { Anim { duration: card.look.motion.duration.short4; curve: card.look.motion.curve.standard } }
        transform: Translate { x: (1 - tray.opacity) * card.look.tray.slide }

        Row {
            id: actionRow
            spacing: card.look.tray.spacing
            Repeater {
                model: card.actions
                PillButton {
                    required property var modelData
                    look: card.look
                    text: modelData.label
                    emphasized: modelData.id !== "dismiss"
                    onClicked: card.actionTriggered(modelData.id)
                }
            }
        }
    }
}
