import QtQuick
import QtQuick.Layouts
import "NotificationLogic.js" as Logic

// One row of the stack on one screen: the card, the glass under it and the
// edge light over it, and the motion around them. A toast morphs in from a
// dot and collapses back into one when it leaves; a panel row fades in and
// out in a cascade. The service owns the row, its lifetime and its end: the
// slot plays what the row's `leaving` names, and the service removes the
// row once that has had its time. The slot tells the service while the
// pointer is on its card, which pauses the toast's clock.
Item {
    id: slot

    // The stack this row is drawn in, which says whether the service is
    // still there.
    required property var host
    // Null once the service or the stack is gone, while the host destroys
    // this copy; every binding on it checks for that.
    readonly property var service: host ? host.service : null
    required property var look
    required property int index
    required property string key
    required property string app
    required property string appIcon
    required property string summary
    required property string body
    required property string image
    required property string desktopEntry
    required property int urgency
    required property string origin
    required property string leaving

    Layout.preferredWidth: card.implicitWidth
    Layout.alignment: Qt.AlignHCenter
    // The slot grows with the morph, so the rows under it slide rather than
    // jump.
    implicitHeight: look.card.gap * stretch + card.height + drop

    // The container transform: `stretch` morphs the dot into the capsule,
    // `drop` lowers the dot into place, `squash` flattens it for a beat as
    // it lands, and `hover` lifts it while the pointer is on it.
    property real stretch: 0
    property real drop: 0
    property real squash: 0
    property real hover: card.hovered && leaving === "" ? 1 : 0
    Behavior on hover { Anim { duration: slot.look.motion.duration.short4; curve: slot.look.motion.curve.standard } }
    readonly property real orbness: 1 - stretch
    // A row being removed reads index -1.
    readonly property int cascade: Math.max(0, Math.min(index, look.motion.staggerRows)) * look.motion.duration.stagger

    // The hover actions, read when the pointer arrives, since a live
    // notification's actions are not observable.
    property var actions: []
    property bool pointerReported: false
    readonly property bool pointerIn: card.hovered
    onPointerInChanged: {
        if (pointerIn) actions = service.actionsFor(key);
        if (pointerIn !== pointerReported) {
            pointerReported = pointerIn;
            service.hover(key, pointerIn);
        }
    }
    Component.onDestruction: if (pointerReported && service !== null) service.hover(key, false)

    Component.onCompleted: {
        if (leaving !== "") play();
        else if (origin === "panel") panelEnter.start();
        else enterAnim.start();
    }
    onLeavingChanged: play()

    function play() {
        enterAnim.stop();
        panelEnter.stop();
        if (leaving === "fade") fadeAnim.start();
        else if (leaving !== "") exitAnim.start();
    }

    SequentialAnimation {
        id: enterAnim
        PropertyAction { target: card; property: "contentOpacity"; value: 0 }
        PropertyAction { target: card; property: "opacity"; value: 0 }
        PropertyAction { target: slot; property: "drop"; value: -slot.look.card.drop }
        ParallelAnimation {
            Anim { target: card; property: "opacity"; to: 1; duration: slot.look.motion.duration.short3; curve: slot.look.motion.curve.standard }
            Anim { target: slot; property: "drop"; to: 0; duration: slot.look.motion.duration.medium1; curve: slot.look.motion.curve.emphasizedDecel }
        }
        Anim { target: slot; property: "squash"; to: 1; duration: slot.look.motion.duration.short2; curve: slot.look.motion.curve.standardDecel }
        ParallelAnimation {
            Anim { target: slot; property: "squash"; to: 0; duration: slot.look.motion.duration.medium2; curve: slot.look.motion.curve.emphasizedDecel }
            Anim { target: slot; property: "stretch"; from: 0; to: 1; duration: slot.look.motion.duration.medium4; curve: slot.look.motion.curve.standard }
            SequentialAnimation {
                PauseAnimation { duration: slot.look.motion.duration.short4 }
                Anim { target: card; property: "contentOpacity"; to: 1; duration: slot.look.motion.duration.short4; curve: slot.look.motion.curve.standard }
            }
        }
    }

    // A panel row only fades in, in a cascade: many morphs at once read as
    // noise.
    SequentialAnimation {
        id: panelEnter
        PropertyAction { target: slot; property: "stretch"; value: 1 }
        PropertyAction { target: card; property: "opacity"; value: 0 }
        PropertyAction { target: card; property: "scale"; value: slot.look.card.panelEnterScale }
        PauseAnimation { duration: slot.cascade }
        ParallelAnimation {
            Anim { target: card; property: "opacity"; to: 1; duration: slot.look.motion.duration.medium1; curve: slot.look.motion.curve.standard }
            Anim { target: card; property: "scale"; to: 1; duration: slot.look.motion.duration.medium2; curve: slot.look.motion.curve.emphasizedDecel }
        }
    }

    // A panel closing: opacity and scale only, so the stack is laid out once,
    // when the rows go together.
    SequentialAnimation {
        id: fadeAnim
        PauseAnimation { duration: slot.cascade }
        ParallelAnimation {
            Anim { target: card; property: "opacity"; to: 0; duration: slot.look.motion.duration.short4; curve: slot.look.motion.curve.emphasizedAccel }
            Anim { target: card; property: "scale"; to: slot.look.card.fadeScale; duration: slot.look.motion.duration.short4; curve: slot.look.motion.curve.emphasizedAccel }
        }
    }

    // A toast leaving collapses to a dot and shrinks away. The text is gone
    // early in the collapse, so it never looks clipped.
    SequentialAnimation {
        id: exitAnim
        ParallelAnimation {
            Anim { target: card; property: "contentOpacity"; to: 0; duration: slot.look.motion.duration.short3; curve: slot.look.motion.curve.emphasizedAccel }
            Anim { target: slot; property: "stretch"; to: 0; duration: slot.look.motion.duration.medium3; curve: slot.look.motion.curve.emphasizedAccel }
        }
        ParallelAnimation {
            Anim { target: card; property: "opacity"; to: 0; duration: slot.look.motion.duration.short3; curve: slot.look.motion.curve.standard }
            Anim { target: card; property: "scale"; to: slot.look.card.exitScale; duration: slot.look.motion.duration.short3; curve: slot.look.motion.curve.emphasizedAccel }
        }
    }

    NotificationCard {
        id: card
        look: slot.look
        anchors.horizontalCenter: parent.horizontalCenter
        y: slot.look.card.gap * slot.stretch + slot.drop - slot.look.card.lift * slot.hover
        width: slot.look.card.dot * (1 + slot.look.card.squashWide * slot.squash) + (card.fullWidth - slot.look.card.dot) * slot.stretch
        height: slot.look.card.dot * (1 - slot.look.card.squashFlat * slot.squash) + (card.fullHeight - slot.look.card.dot) * slot.stretch
        app: slot.app
        appIcon: slot.appIcon
        summary: slot.summary
        body: slot.body
        image: slot.image
        desktopEntry: slot.desktopEntry
        workspace: slot.service !== null ? slot.service.workspaceOf(card.enrichment) : ""
        workspaceIcon: slot.service !== null && card.enrichment !== null ? slot.service.workspaceIcon(card.enrichment.rule, card.workspace) : ""
        faceImages: slot.service !== null && card.enrichment !== null ? slot.service.faceImages(card.enrichment, slot.image, card.workspace) : []
        actions: slot.actions
        showActions: card.hovered && slot.leaving === ""
        onActionTriggered: id => slot.service.runAction(slot.key, id)
        onCloseRequested: slot.service.dismiss(slot.key)
        onCardClicked: slot.service.invoke(slot.key)
    }

    GlassSurface {
        z: -1
        look: slot.look
        follow: card
        orb: slot.orbness * slot.orbness
    }

    EdgeLight {
        look: slot.look
        follow: card
        // A full panel lights only the card under the pointer, and a closing
        // one lights nothing, so its rows fade out dark.
        visible: slot.leaving !== "fade" && (slot.hover > 0 || (slot.service !== null && !slot.service.panelOpen && !slot.service.panelClosing))
        active: slot.urgency === Logic.URGENCY.critical
        spin: slot.look.edge.spin * slot.orbness
        boost: 1 + slot.look.edge.orbBoost * slot.orbness + slot.look.edge.hoverBoost * slot.hover
    }
}
