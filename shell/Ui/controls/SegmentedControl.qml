import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One choice among a few, drawn as adjoining segments: `model` lists the
// segment texts and `currentIndex` the chosen one. A click or the left and
// right keys move it; `activated` fires on a change the user made. The
// control is one tab stop: the segments take no focus of their own, so the
// ring draws around the whole control and the keys act on it. A segment
// that is not chosen fills on hover and more on a press; a segment's
// corner is the control's less its inset, so it nests in a rounded
// control, and a disabled control fades.
Rectangle {
    id: root

    property var model: []
    property int currentIndex: 0
    signal activated(int index)

    function choose(index) {
        if (index < 0 || index >= model.length || index === currentIndex) return;
        currentIndex = index;
        activated(index);
    }

    implicitWidth: row.implicitWidth + 2 * Theme.segmented.padding
    implicitHeight: Theme.segmented.height
    radius: Theme.segmented.radius
    color: Theme.segmented.background
    border.width: Theme.border.thin
    border.color: Theme.segmented.border
    activeFocusOnTab: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    Keys.onLeftPressed: choose(currentIndex - 1)
    Keys.onRightPressed: choose(currentIndex + 1)

    Row {
        id: row
        x: Theme.segmented.padding
        y: Theme.segmented.padding
        height: parent.height - 2 * Theme.segmented.padding
        spacing: Theme.segmented.gap

        Repeater {
            model: root.model
            T.Button {
                id: segment
                required property int index
                required property var modelData
                readonly property bool current: index === root.currentIndex

                height: row.height
                focusPolicy: Qt.NoFocus
                implicitWidth: implicitContentWidth + leftPadding + rightPadding
                leftPadding: Theme.controlPadding(Theme.segmented.paddingX, Math.max(0, Theme.segmented.radius - Theme.segmented.padding), row.height, implicitContentHeight)
                rightPadding: leftPadding
                hoverEnabled: true
                PointerCursor {}
                text: String(modelData)
                Accessible.name: text
                onClicked: { root.forceActiveFocus(); root.choose(index); }

                contentItem: Label {
                    role: "button"
                    text: segment.text
                    color: segment.current ? Theme.segmented.selectedForeground : Theme.segmented.foreground
                    verticalAlignment: Text.AlignVCenter
                }

                background: Rectangle {
                    radius: Math.max(0, Theme.segmented.radius - Theme.segmented.padding)
                    color: segment.current ? Theme.segmented.selected : segment.down ? Theme.segmented.pressed : segment.hovered ? Theme.segmented.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
                }
            }
        }
    }

    FocusRing { target: root; targetRadius: Theme.segmented.radius }
}
