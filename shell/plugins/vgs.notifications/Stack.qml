import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Appearance.js" as Appearance

// The stack on one screen, the content the service hands its layer: the
// toasts, centred at the top of the screen below the space the bar
// reserves. The layer host builds one per screen and assigns `screen`.
// Presses reach only the toast cards. It keeps no keyboard. The host
// destroys a copy a moment after the service that declared it can already
// be gone, so every binding on the service checks it for null, and the look is
// the stack's own reading of the same table.
Item {
    id: stack

    property var screen: null
    required property var service
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)
    readonly property bool inputAll: false
    readonly property var inputItems: [column]

    ColumnLayout {
        id: column
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: stack.look.stack.top
        // Each slot carries its own gap, scaled by its morph, so the rows
        // close up smoothly when one goes.
        spacing: 0

        CardScroll {
            id: scroll
            look: stack.look
            maxHeight: stack.height - column.y - stack.look.stack.bottom
            scrollObjectName: "notificationScrollBar"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight

            Repeater {
                model: stack.service !== null ? stack.service.rows : null
                CardSlot {
                    host: stack
                    look: stack.look
                    textColumn: scroll.textColumn
                }
            }
        }
    }
}
