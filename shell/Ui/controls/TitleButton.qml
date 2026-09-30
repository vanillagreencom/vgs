import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A title that names the current choice and opens a menu of the others:
// its text in `role` with a down caret after it, centred on the text's
// capital centre on a whole pixel. A click, Space, Enter or Down toggles
// `menu`, a Menu the author declares inside the button, so the menu opens
// under the title. The text and the caret take `titleButton.hover` while
// hovered or open, and the underline under the text shows then and while
// the button holds keyboard focus; at rest the caret alone marks the menu.
// The template owns the click, hover and focus.
T.AbstractButton {
    id: root

    // The typography role of the title, a group of `Theme.text`.
    property string role: "h3"
    // The menu the title opens; null opens nothing.
    property Item menu: null
    readonly property bool menuOpen: menu !== null && menu.opened
    readonly property color foreground: hovered || menuOpen ? Theme.titleButton.hover : Theme.titleButton.foreground
    readonly property bool engaged: hovered || menuOpen || visualFocus
    // The title's capital centre from the button's top, so a header puts
    // the text, not the box with its underline, on its centre line.
    readonly property real capCentre: topPadding + label.capCentre

    function toggleMenu() { if (menu !== null) menu.toggle(); }

    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: implicitContentHeight + topPadding + bottomPadding
    padding: 0
    spacing: Theme.titleButton.gap
    hoverEnabled: true
    PointerCursor {}
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text
    Accessible.role: Accessible.ButtonMenu
    onClicked: toggleMenu()
    Keys.onReturnPressed: toggleMenu()
    Keys.onEnterPressed: toggleMenu()
    Keys.onDownPressed: toggleMenu()

    // The title takes its own width, and elides only when the button is
    // given less than the title and the caret need.
    contentItem: Item {
        implicitWidth: label.implicitWidth + root.spacing + caret.width
        implicitHeight: Math.max(label.implicitHeight + Theme.titleButton.underlineGap + Theme.titleButton.underline, caret.height)

        Label {
            id: label
            role: root.role
            text: root.text
            color: root.foreground
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width - root.spacing - caret.width)
        }
        Rectangle {
            id: underline
            y: label.height + Theme.titleButton.underlineGap
            width: label.width
            height: Theme.titleButton.underline
            color: root.hovered || root.menuOpen ? root.foreground : Theme.titleButton.underlineColor
            visible: root.engaged
        }
        Icon {
            id: caret
            name: "chevron-down"
            size: Theme.icon.size.sm
            color: root.hovered || root.menuOpen ? root.foreground : Theme.titleButton.caret
            x: label.width + root.spacing
            y: Math.round(label.capCentre - height / 2)
        }
    }

    background: Item {
        FocusRing { target: root }
    }
}
