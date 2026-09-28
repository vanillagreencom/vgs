import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Appearance.js" as Appearance

// The stack on one screen, the content the service hands its layer: the
// panel's header, and under it the toasts and the panel's rows, centred at
// the top of the screen below the space the bar reserves. The layer host
// builds one per screen and assigns `screen`. Presses reach only the stack
// while no panel is open; with one open the whole screen takes them, so a
// press outside the stack closes the panel. It keeps no keyboard. The host
// destroys a copy a moment after the service that declared it can already
// be gone, so every binding on the service checks it for null, and the look is
// the stack's own reading of the same table.
Item {
    id: stack

    property var screen: null
    required property var service
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)
    readonly property bool panelOpen: service !== null && service.panelOpen
    readonly property bool panelClosing: service !== null && service.panelClosing
    readonly property bool inputAll: panelOpen
    readonly property Item inputItem: column

    MouseArea {
        anchors.fill: parent
        enabled: stack.panelOpen
        acceptedButtons: Qt.AllButtons
        onPressed: stack.service.closePanel()
    }

    ColumnLayout {
        id: column
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: stack.look.stack.top
        // Each slot carries its own gap, scaled by its morph, so the rows
        // close up smoothly when one goes.
        spacing: 0

        InboxHeader {
            id: header
            look: stack.look
            host: stack
            shown: stack.panelOpen
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: implicitWidth
            // Keeps its height until the closing rows are gone, then folds.
            property real room: stack.panelOpen || stack.panelClosing ? 1 : 0
            Behavior on room { Anim { duration: stack.look.motion.duration.medium2; curve: stack.look.motion.curve.standard } }
            Layout.preferredHeight: implicitHeight * room
            Layout.bottomMargin: stack.look.header.gap * room
        }

        // The stack scrolls once it outgrows the screen, as a full panel does.
        Flickable {
            id: view
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: cards.implicitWidth + stack.look.stack.pad * 2
            Layout.preferredHeight: Math.min(cards.implicitHeight + stack.look.stack.tail, stack.height - column.y - header.height - stack.look.stack.bottom)
            contentWidth: width
            contentHeight: cards.implicitHeight + stack.look.stack.tail
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            clip: true

            ColumnLayout {
                id: cards
                x: stack.look.stack.pad
                spacing: 0

                Repeater {
                    model: stack.service !== null ? stack.service.rows : null
                    CardSlot {
                        host: stack
                        look: stack.look
                    }
                }
            }
        }
    }
}
