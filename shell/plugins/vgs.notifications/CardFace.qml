import QtQuick
import "NotificationLogic.js" as Logic

// The shared notification face: one card, the glass behind it, the edge
// light over it and the hover report every surface sends to the service.
Item {
    id: face

    required property var look
    required property real textColumn
    required property string key
    property string app: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property string image: ""
    property string desktopEntry: ""
    property int urgency: Logic.URGENCY.normal
    property string hintIcon: ""
    property string hintTone: ""
    property string workspace: ""
    property string workspaceIcon: ""
    property var faceImages: []
    property var emoji: null
    property var actions: []
    property bool showActions: false
    property int actionIndex: -1
    property real orb: 0
    property real edgeSpin: 0
    property real edgeBoost: 1
    property bool edgeVisible: false
    property bool reportHover: true
    readonly property bool hovered: card.hovered
    readonly property alias card: card

    signal actionTriggered(string id)
    signal closeRequested()
    signal cardClicked()
    signal hoverRequested(string key, bool on)

    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight

    property bool hoverReported: false
    onHoveredChanged: {
        if (!reportHover || key === "" || hovered === hoverReported) return;
        hoverReported = hovered;
        hoverRequested(key, hovered);
    }
    Component.onDestruction: {
        if (hoverReported && reportHover && key !== "") hoverRequested(key, false);
    }

    NotificationCard {
        id: card
        look: face.look
        textColumn: face.textColumn
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        height: parent.height
        app: face.app
        appIcon: face.appIcon
        summary: face.summary
        body: face.body
        image: face.image
        desktopEntry: face.desktopEntry
        hintIcon: face.hintIcon
        hintTone: face.hintTone
        workspace: face.workspace
        workspaceIcon: face.workspaceIcon
        faceImages: face.faceImages
        emoji: face.emoji
        actions: face.actions
        showActions: face.showActions
        actionIndex: face.actionIndex
        onActionTriggered: id => face.actionTriggered(id)
        onCloseRequested: face.closeRequested()
        onCardClicked: face.cardClicked()
    }

    GlassSurface {
        z: -1
        look: face.look
        follow: card
        orb: face.orb
    }

    EdgeLight {
        look: face.look
        follow: card
        visible: face.edgeVisible
        active: face.urgency === Logic.URGENCY.critical
        spin: face.edgeSpin
        boost: face.edgeBoost
    }
}
