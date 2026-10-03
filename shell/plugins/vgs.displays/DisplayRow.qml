import QtQuick
import qs.Commons
import qs.Ui
import "DisplaysLogic.js" as Logic

// One display's row, in the flyout and in the pane: its name, then a
// Slider and its level while it is ready, or what keeps it from being
// ready and, when its access entry offers it (`status.rows`), the entry's
// action, which runs through `status.act`. The slider asks the service's
// `set` for each move; the service follows linked displays and coalesces
// the runs. Width comes from the parent.
FormRow {
    id: root

    property var shell: null
    // The display as the `displays` status lists it.
    property var display: null
    // The access action that makes the display ready, { key, label }, while
    // its entry offers it, else null.
    readonly property var action: {
        const key = display === null || shell === null ? null : Logic.accessKey(display);
        if (key === null) return null;
        const row = shell.status.rows.find(r => r.key === key);
        return row === undefined || row.action === null || !row.action.offered ? null : { key: key, label: row.action.label };
    }
    readonly property bool ready: display !== null && display.state === "ready"
    readonly property alias slider: slider
    // The refusal the last step was answered with, "" for none.
    property string problem: ""

    label: display === null ? "" : display.label

    // Ask the service for PERCENT on this display; answers its reply.
    function setPercent(percent) {
        const reply = shell.ipc.call("set", JSON.stringify({ id: display.id, percent: percent }));
        problem = Logic.replyText(reply);
        if (reply !== "ok") console.warn("displays: " + reply);
        return reply;
    }

    // Run this display's access action; answers the core's reply.
    function allow() {
        const reply = shell.status.act(action.key);
        problem = Logic.replyText(reply);
        if (reply !== "ok") console.warn("displays: " + action.key + " " + reply);
        return reply;
    }

    Column {
        width: parent.width
        spacing: Theme.row.lineGap

        Row {
            width: parent.width
            spacing: Theme.stack.inline
            visible: root.ready

            Slider {
                id: slider
                width: parent.width - level.width - parent.spacing
                from: Logic.MIN_PERCENT
                to: Logic.MAX_PERCENT
                stepSize: 1
                value: root.ready ? root.display.percent : Logic.MIN_PERCENT
                Accessible.name: root.label
                // A key's move assigns `value`, which drops the binding:
                // restore it so the handle follows every later change.
                onMoved: {
                    root.setPercent(Math.round(value));
                    value = Qt.binding(() => root.ready ? root.display.percent : Logic.MIN_PERCENT);
                }
            }
            Label {
                id: level
                anchors.verticalCenter: parent.verticalCenter
                width: widest.implicitWidth
                role: "value"
                horizontalAlignment: Text.AlignRight
                text: root.ready ? root.display.percent + "%" : ""
                Label { id: widest; visible: false; role: "value"; text: "100%" }
            }
        }

        Row {
            width: parent.width
            spacing: Theme.stack.inline
            visible: !root.ready && root.display !== null

            Label {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - (allowButton.visible ? allowButton.width + parent.spacing : 0)
                role: "body"
                color: Theme.color.textMuted
                text: root.display === null ? "" : Logic.stateText(root.display.state)
                wrapMode: Text.Wrap
            }
            Button {
                id: allowButton
                visible: root.action !== null
                variant: "secondary"
                size: "sm"
                text: root.action === null ? "" : root.action.label
                onClicked: root.allow()
            }
        }

        Label {
            width: parent.width
            visible: text !== ""
            role: "hint"
            color: Theme.color.danger
            text: root.problem
            wrapMode: Text.Wrap
        }
    }
}
