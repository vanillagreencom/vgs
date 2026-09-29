import QtQuick
import qs.Commons

// The panel's header over the stack while the Inbox or the History is open:
// its title and subtitle, the Silence switch, Mark read (Inbox) or Clear
// history (History), and the switch between the two. It reads and drives
// the service through the stack; it holds no state of its own.
Item {
    id: header

    required property var look
    required property var host
    // Null once the service or the stack is gone, while the host destroys
    // this copy; every binding on it checks for that.
    readonly property var service: host ? host.service : null
    property bool shown: false
    readonly property bool history: service !== null && service.panelMode === "history"
    readonly property real titleInset: Inset.clearing(look.header.controlsInset, look.radius.full, width, height, look.radius.clearance)

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
        anchors.left: parent.left
        anchors.leftMargin: header.titleInset
        anchors.verticalCenter: parent.verticalCenter
        spacing: header.look.header.lineGap

        Text {
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
            textFormat: Text.PlainText
            visible: text.length > 0
            text: header.service !== null ? header.service.panelSubtitle : ""
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
                look: header.look
                checked: header.service !== null && header.service.silenced
                onToggled: checked => header.service.setSilence(checked)
            }
        }

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            look: header.look
            text: header.history ? "Clear history" : "Mark read"
            onClicked: header.history ? header.service.clearHistoryPanel() : header.service.markRead()
        }

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            look: header.look
            text: header.history ? "Unread" : "History"
            emphasized: header.history
            onClicked: header.service.openPanel(header.history ? "inbox" : "history")
        }
    }
}
