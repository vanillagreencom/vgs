import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.Ui
import "NotificationLogic.js" as Logic

// One notification as a glass capsule: its image or application icon, its
// summary and its body, and the hover actions over its right end. A sender
// a NotificationLogic rule reads shows the people it names as faces in the
// icon's place, and the workspace its summary names as that workspace's
// icon, when there is one, in place of the name. It draws no fill of its
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
    // The file URL of the icon of the workspace `enrichment` names, or "".
    property string workspaceIcon: ""
    // One file URL per face, from the optional Slack token cache.
    property var faceImages: []
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
    readonly property string iconSource: image.length > 0 ? image : iconPath(appIcon)
    readonly property string sanitizedBody: Logic.sanitizeBody(body, app, appIcon)
    readonly property bool singleLine: sanitizedBody.length === 0
    readonly property bool iconInSummary: singleLine && Logic.summaryStartsWithGlyph(summary)
    readonly property bool showsIcon: !iconInSummary && iconSource.length > 0 && iconImage.status !== Image.Error
    // NotificationLogic.enrich's reading of this sender, or null.
    readonly property var enrichment: Logic.enrich(app, desktopEntry, summary, body)
    readonly property bool showsFaces: enrichment !== null && enrichment.faces.length > 0
    readonly property bool showsBadge: enrichment !== null && enrichment.workspace.length > 0 && workspaceIcon.length > 0 && badgeImage.status === Image.Ready
    readonly property bool showsSlot: showsFaces || showsIcon
    // The summary as drawn: without the workspace name its icon replaces.
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
        width: card.fullWidth - 2 * card.pad
        opacity: card.contentOpacity
        spacing: card.showsSlot ? card.look.card.gapIcon : 0

        Item {
            id: iconSlot
            Layout.preferredWidth: card.showsFaces ? faceStack.implicitWidth : card.showsIcon ? card.look.card.icon : 0
            Layout.preferredHeight: card.showsFaces ? faceStack.implicitHeight : card.showsIcon ? card.look.card.icon : 0
            Layout.alignment: Qt.AlignVCenter
            visible: card.showsSlot

            Faces {
                id: faceStack
                look: card.look
                visible: card.showsFaces
                names: card.showsFaces ? card.enrichment.faces : []
                more: card.showsFaces ? card.enrichment.more : 0
                image: card.image
                images: card.showsFaces ? card.faceImages : []
            }

            Image {
                id: iconImage
                anchors.fill: parent
                visible: !card.showsFaces
                source: card.iconInSummary ? "" : card.iconSource
                sourceSize.width: card.look.card.icon * Screen.devicePixelRatio
                sourceSize.height: card.look.card.icon * Screen.devicePixelRatio
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
            }
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
                        source: card.enrichment !== null && card.enrichment.workspace.length > 0 ? card.workspaceIcon : ""
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
            }

            Text {
                id: bodyText
                // The height left for the body under maxHeight, and so the
                // whole lines it shows; the last one elides.
                readonly property real room: card.look.card.maxHeight - 2 * card.pad - Layout.topMargin - (summaryRow.visible ? summaryRow.implicitHeight + textBlock.spacing : 0)
                Layout.fillWidth: true
                Layout.topMargin: card.look.card.lineGap
                visible: !card.singleLine
                // StyledText, since the server advertises body markup;
                // NotificationLogic strips every image tag first.
                text: Logic.styledBody(card.body, card.app, card.appIcon)
                textFormat: Text.StyledText
                color: card.look.text.foreground
                opacity: card.look.text.subtitle.opacity
                font.family: card.look.font.family
                font.pixelSize: card.look.text.subtitle.size
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
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
