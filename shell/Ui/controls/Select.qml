import QtQuick
import QtQuick.Templates as T
import Quickshell
import qs.Commons
import qs.Ui

// A dropdown choice. `model` is a list of strings, or of objects with
// `textRole` naming the text; `currentIndex` is the choice. A click, Space
// or Enter opens the list in its own surface under the control; Up and
// Down move the highlight there and Enter chooses, a click chooses, and a
// press outside or Escape closes it. With the list closed, Up and Down on
// the focused control move the choice. The control draws like a text
// field; the template owns its click, hover and focus.
T.AbstractButton {
    id: root

    property var model: []
    property int currentIndex: 0
    property string textRole: ""
    readonly property int count: Array.isArray(model) ? model.length : 0
    readonly property string currentText: textAt(currentIndex)
    readonly property bool listOpen: list.visible
    readonly property color outline: activeFocus || list.visible ? Theme.textField.focus : hovered ? Theme.textField.hover : Theme.textField.borderColor

    function textAt(index) {
        if (index < 0 || index >= count) return "";
        const entry = model[index];
        if (textRole !== "" && entry !== null && typeof entry === "object") return String(entry[textRole]);
        return String(entry);
    }

    // Choose the entry at `index` and close the list.
    function choose(index) {
        if (index < 0 || index >= count) return;
        currentIndex = index;
        list.visible = false;
    }

    function openList() {
        if (count === 0) return;
        entries.currentIndex = currentIndex;
        list.visible = true;
        entries.forceActiveFocus();
    }

    // The open list's rectangle in the coordinates of the window the
    // control draws in, as JSON, or "closed".
    function listGeometry() {
        if (!list.visible) return "closed";
        const p = entries.mapToGlobal(0, 0);
        return JSON.stringify([p.x - Theme.menu.padding, p.y - Theme.menu.padding, list.width, list.height]);
    }

    implicitWidth: Theme.size.panel.sm / 2
    implicitHeight: Theme.textField.height
    leftPadding: Theme.textField.paddingX
    rightPadding: Theme.textField.paddingX + Theme.icon.size.sm + Theme.textField.gap
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: currentText
    onClicked: if (list.visible) list.visible = false; else openList()
    Keys.onUpPressed: choose(currentIndex - 1)
    Keys.onDownPressed: choose(currentIndex + 1)

    contentItem: Label {
        role: "body"
        text: root.currentText
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    indicator: Icon {
        name: "chevron-down"
        size: Theme.icon.size.sm
        color: Theme.textField.icon
        x: root.width - width - Theme.textField.paddingX
        y: (root.height - height) / 2
    }

    background: Rectangle {
        radius: Theme.textField.radius
        color: Theme.textField.background
        border.width: Theme.textField.border
        border.color: root.outline
        Behavior on border.color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root }
    }

    PopupWindow {
        id: list

        anchor.item: root
        anchor.edges: Edges.Bottom | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
        anchor.margins.bottom: -Theme.select.gap
        grabFocus: true
        visible: false
        color: "transparent"
        implicitWidth: Math.max(1, root.width)
        implicitHeight: Math.max(1, Math.min(Theme.select.maxHeight, entries.contentHeight + 2 * Theme.menu.padding))
        onVisibleChanged: visible ? OverlayState.opened() : OverlayState.closed()

        Rectangle {
            anchors.fill: parent
            radius: Theme.menu.radius
            color: Theme.menu.background
            border.width: Theme.border.thin
            border.color: Theme.menu.border
        }

        ListView {
            id: entries
            anchors.fill: parent
            anchors.margins: Theme.menu.padding
            model: root.model
            clip: true
            focus: true
            keyNavigationEnabled: true
            keyNavigationWraps: false
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: Theme.motion.duration.fast
            Keys.onReturnPressed: root.choose(currentIndex)
            Keys.onEnterPressed: root.choose(currentIndex)
            Keys.onEscapePressed: list.visible = false

            delegate: T.ItemDelegate {
                id: entry
                required property int index
                readonly property bool chosen: index === root.currentIndex

                width: ListView.view.width
                implicitHeight: Theme.menu.item.height
                leftPadding: Theme.menu.item.paddingX
                rightPadding: Theme.menu.item.paddingX
                text: root.textAt(index)
                highlighted: ListView.isCurrentItem
                hoverEnabled: true
                Accessible.name: text
                onClicked: root.choose(index)
                onHoveredChanged: if (hovered) entries.currentIndex = index

                contentItem: Label {
                    role: "body"
                    text: entry.text
                    color: entry.chosen ? Theme.select.selectedForeground : Theme.menu.item.foreground
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }

                background: Rectangle {
                    radius: Theme.menu.item.radius
                    color: entry.chosen ? Theme.select.selected : entry.highlighted ? Theme.select.highlight : "transparent"
                }
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: list; anchor: root }
}
