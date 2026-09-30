import QtQuick
import qs.Commons
import qs.Ui

// A command or path the reader copies: the text in the code role on a
// sunken fill, wrapped at word boundaries, or inside a word longer than a
// line, so a long command shows whole. Under a rounded theme the text and
// the button sit in from the sides until they clear the drawn corner. A single
// line is placed by capital height on the box centre. Wrapped text is
// top-aligned with CSS half-leading, so the top and bottom padding are
// equal around the line boxes. The Copy button, an `IconButton` of size
// `sm`, sits inside the padding at the top right. The text is read-only
// and takes no focus. `copy()`, which the button calls, puts `text` on the
// clipboard, emits `copied()` and shows a check mark on the button for
// `codeLine.confirm` milliseconds. `copyLabel` is what a screen reader and
// a tooltip say for the button.
Rectangle {
    id: root

    property string text: ""
    property string copyLabel: "Copy"
    // True while the button shows its check mark after a copy.
    readonly property bool confirming: confirm.running

    signal copied()

    onTextChanged: sideInset.reset()

    ClearingInset {
        id: sideInset
        pad: Theme.codeLine.padding
        radius: Theme.codeLine.radius
        width: root.width
        height: root.implicitHeight
        top: Theme.codeLine.padding
    }

    function copy() {
        clipboard.text = root.text;
        clipboard.selectAll();
        clipboard.copy();
        clipboard.deselect();
        confirm.restart();
        root.copied();
    }

    implicitWidth: 2 * sideInset.inset + label.implicitWidth + Theme.codeLine.gap + button.implicitWidth
    implicitHeight: 2 * Theme.codeLine.padding + Math.max(Math.max(1, label.lineCount) * label.lineBox, button.implicitHeight)
    radius: Theme.codeLine.radius
    color: Theme.codeLine.background
    border.width: Theme.codeLine.border
    border.color: Theme.codeLine.borderColor

    Label {
        id: label
        role: "code"
        text: root.text
        color: Theme.codeLine.foreground
        x: sideInset.inset
        y: lineCount <= 1 ? topForCapCenter(root.height) : Theme.codeLine.padding + halfLeading
        width: Math.max(0, button.x - Theme.codeLine.gap - x)
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
    }

    IconButton {
        id: button
        size: "sm"
        iconName: root.confirming ? "check" : "copy"
        label: root.copyLabel
        x: root.width - width - sideInset.inset
        y: Theme.codeLine.padding
        onClicked: root.copy()
    }

    // The clipboard is the application's, reached through a text edit's
    // copy, so the component imports no Quickshell module.
    TextEdit {
        id: clipboard
        visible: false
        readOnly: true
    }

    Timer {
        id: confirm
        interval: Theme.codeLine.confirm
    }
}
