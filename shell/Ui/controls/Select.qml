import QtQuick
import QtQuick.Templates as T
import Quickshell
import qs.Commons
import qs.Ui

// A dropdown choice. `model` is a list of strings, or of objects with
// `textRole` naming the text; `currentIndex` is the choice. A click, Space
// or Enter opens the list in its own surface under the control; Up and
// Down move the highlight there and Enter chooses, a click chooses, and a
// press outside or Escape closes it. One ListCursor draws the highlight
// and travels between entries, and a hover moves it once the pointer moves
// (ListCursor). With the list closed, Up and Down on the focused control
// move the choice. A list taller than `menu.maxHeight` scrolls under the
// module's embedded bar, which sits in the list's right inset, so the
// entries never move when they overflow. The list opens `menu.padding`
// left of the control and that much wider on each side, so its entries'
// text starts where the control's does. The control draws like a text
// field; the template owns its click, hover and focus.
T.AbstractButton {
    id: root

    property var model: []
    property int currentIndex: 0
    property string textRole: ""
    readonly property int count: Array.isArray(model) ? model.length : 0
    readonly property string currentText: textAt(currentIndex)
    readonly property bool listOpen: list.visible
    property bool counted: false
    // A user choice only. Model and binding updates never emit this.
    signal activated(int index)

    function share(open) {
        if (open === counted) return;
        counted = open;
        if (open) OverlayState.opened(); else OverlayState.closed();
    }
    Component.onDestruction: share(false)
    readonly property color outline: activeFocus || list.visible ? Theme.textField.focus : hovered ? Theme.textField.hover : Theme.textField.borderColor
    readonly property real sidePadding: Theme.controlPadding(Theme.textField.paddingX, Theme.textField.radius, Math.max(Theme.textField.height, height), implicitContentHeight)

    function textAt(index) {
        if (index < 0 || index >= count) return "";
        const entry = model[index];
        if (textRole !== "" && entry !== null && typeof entry === "object") return String(entry[textRole]);
        return String(entry);
    }

    // Choose the entry at `index` and close the list. Choosing the current
    // entry assigns nothing, so a binding on `currentIndex` survives it.
    function choose(index) {
        if (index < 0 || index >= count) return;
        if (index !== currentIndex) currentIndex = index;
        activated(index);
        list.visible = false;
    }

    function openList() {
        if (count === 0) return;
        // The cursor lands on the choice rather than travelling from where
        // the last opening left it.
        plate.disarm();
        plate.snap();
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
    leftPadding: sidePadding
    rightPadding: sidePadding + Theme.icon.size.sm + Theme.textField.gap
    hoverEnabled: true
    PointerCursor {}
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: currentText
    onClicked: if (list.visible) list.visible = false; else openList()
    Keys.onUpPressed: choose(currentIndex - 1)
    Keys.onDownPressed: choose(currentIndex + 1)
    Keys.onReturnPressed: openList()
    Keys.onEnterPressed: openList()

    contentItem: Label {
        role: "item"
        text: root.currentText
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    indicator: Icon {
        name: "chevron-down"
        size: Theme.icon.size.sm
        color: Theme.textField.icon
        x: root.width - width - root.sidePadding
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
        anchor.margins.left: -Theme.menu.padding
        grabFocus: true
        visible: false
        color: "transparent"
        // The field's width and the menu padding either side, never wider
        // than the output's room.
        implicitWidth: Math.max(1, OverlayState.widthFor(root, root.width + 2 * Theme.menu.padding))
        implicitHeight: Math.max(1, Math.min(Theme.menu.maxHeight, entries.contentHeight) + 2 * Theme.menu.padding)
        onVisibleChanged: root.share(visible)

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
            anchors.topMargin: Theme.menu.padding
            anchors.bottomMargin: Theme.menu.padding
            anchors.leftMargin: Theme.menu.padding
            model: root.model
            clip: true
            focus: true
            keyNavigationEnabled: true
            keyNavigationWraps: false
            boundsBehavior: Flickable.StopAtBounds
            readonly property bool overflowing: contentHeight > height
            // A key moves the highlight: the pointer resting over the list
            // takes it again only once it moves. The key goes on to the view.
            Keys.onPressed: event => { plate.disarm(); event.accepted = false; }
            Keys.onReturnPressed: root.choose(currentIndex)
            Keys.onEnterPressed: root.choose(currentIndex)
            Keys.onEscapePressed: list.visible = false

            delegate: T.ItemDelegate {
                id: entry
                required property int index
                readonly property bool chosen: index === root.currentIndex

                width: ListView.view.width - Theme.menu.padding
                implicitHeight: Theme.menu.item.height
                leftPadding: root.sidePadding
                rightPadding: root.sidePadding
                text: root.textAt(index)
                highlighted: ListView.isCurrentItem
                hoverEnabled: true
                PointerCursor {}
                Accessible.name: text
                onClicked: root.choose(index)

                ListCursorRow {
                    cursor: plate
                    holds: entry.highlighted
                    onPointed: entries.currentIndex = entry.index
                }

                contentItem: Label {
                    role: "item"
                    text: entry.text
                    color: entry.chosen ? Theme.select.selectedForeground : Theme.menu.item.foreground
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }

                background: Rectangle {
                    radius: Theme.menu.item.radius
                    color: entry.chosen ? Theme.select.selected : "transparent"
                }
            }

            ListCursor {
                id: plate
                parent: entries.contentItem
                color: Theme.select.highlight
                pressedColor: Theme.menu.item.pressed
                radius: Theme.menu.item.radius
            }

            HoverHandler { id: listHover }

            ScrollBar {
                flickable: entries
                hovered: listHover.hovered
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: list; anchor: root }
}
