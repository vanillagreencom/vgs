import QtQuick
import qs.Commons

// The panel's header over the stack while the Inbox or the History is open:
// its title and subtitle, the Silence switch, Mark read (Inbox) or Clear
// history (History), and the switch between the two. Its caller supplies
// state and handles each request.
Item {
    id: header

    required property var look
    property string mode: "inbox"
    property string subtitle: ""
    property bool silenced: false
    property bool shown: false
    readonly property bool history: mode === "history"
    // The stack's text column, which the cards' text starts on.
    required property real textColumn
    signal silenceRequested(bool on)
    signal clearRequested()
    signal markReadRequested()
    signal modeRequested(string mode)
    // The title starts on the cards' column, and never under the header's
    // own rounded end: the controls inset is the square-corner floor.
    readonly property real titleInset: Math.max(textColumn, Math.ceil(Inset.clearing(look.header.controlsInset, look.radius.full, width, height, look.radius.clearance, titles.y)))

    implicitWidth: look.header.width
    implicitHeight: look.header.height
    opacity: shown ? 1 : 0
    visible: opacity > 0
    transform: Translate { y: header.shown ? 0 : -header.look.header.drop }
    Behavior on opacity { Anim { duration: header.look.motion.duration.medium1; curve: header.look.motion.curve.standard } }

    GlassSurface {
        anchors.fill: parent
        look: header.look
    }

    Column {
        id: titles
        anchors.left: parent.left
        anchors.leftMargin: header.titleInset
        anchors.verticalCenter: parent.verticalCenter
        spacing: header.look.header.lineGap

        Text {
            objectName: "notificationHeaderTitleText"
            textFormat: Text.PlainText
            text: header.history ? "History" : "Notifications"
            color: header.look.text.foreground
            font.family: header.look.font.family
            font.pixelSize: header.look.text.title.size
            font.weight: header.look.text.title.weight
            style: Text.Raised
            styleColor: header.look.text.shadow
        }
        Text {
            objectName: "notificationHeaderSubtitleText"
            textFormat: Text.PlainText
            visible: text.length > 0
            text: header.subtitle
            color: header.look.text.foreground
            opacity: header.look.text.subtitle.opacity
            font.family: header.look.font.family
            font.pixelSize: header.look.text.subtitle.size
        }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: header.look.header.controlsInset
        anchors.verticalCenter: parent.verticalCenter
        spacing: header.look.header.controlsGap

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: header.look.header.labelGap
            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Silence"
                color: header.look.text.foreground
                opacity: header.look.text.label.opacity
                font.family: header.look.font.family
                font.pixelSize: header.look.text.label.size
            }
            Toggle {
                anchors.verticalCenter: parent.verticalCenter
                height: header.look.toggle.hitHeight
                look: header.look
                checked: header.silenced
                text: "Silence"
                onClicked: header.silenceRequested(!header.silenced)
            }
        }

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            look: header.look
            text: header.history ? "Clear history" : "Mark read"
            onClicked: header.history ? header.clearRequested() : header.markReadRequested()
        }

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            look: header.look
            text: header.history ? "Unread" : "History"
            emphasized: header.history
            onClicked: header.modeRequested(header.history ? "inbox" : "history")
        }
    }
}
