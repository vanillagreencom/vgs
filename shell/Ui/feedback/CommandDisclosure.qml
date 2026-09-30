import QtQuick
import qs.Commons
import qs.Ui

// The "Show command" disclosure (D058): the command behind a one-click
// setup step, shown on request so a reader who wants to run it by hand can
// copy it. A ghost `Button` reading "Show command", or "Hide command" while
// `expanded`, toggles a `CodeLine` of `command` under it; hidden, the line
// takes no height. With `command` "" nothing draws. It is the secondary
// route: it sits beside the button that runs the step, never alone.
Column {
    id: root

    property string command: ""
    property bool expanded: false
    // What a screen reader and a tooltip say for the line's Copy button.
    property string copyLabel: "Copy the command"
    readonly property alias toggle: toggleButton
    readonly property alias line: codeLine

    visible: command !== ""
    spacing: Theme.field.gap

    Button {
        id: toggleButton
        text: root.expanded ? "Hide command" : "Show command"
        iconName: "terminal"
        variant: "ghost"
        size: "sm"
        onClicked: root.expanded = !root.expanded
    }

    CodeLine {
        id: codeLine
        width: root.width
        visible: root.expanded
        text: root.command
        copyLabel: root.copyLabel
    }
}
