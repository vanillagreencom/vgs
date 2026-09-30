import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ViewLogic.js" as View

// The Agent Warden flyout: a heading, one status sentence, at most three
// items with no process id or scope name, the agent group's memory meter
// when it is known, vsys's own verdict on the computer when vsys is
// installed, and a footer with the check time and a link to vsys. A state
// that needs setting up offers its one button instead: Set up or Update
// opens the `setup` TUI, Start it starts the warden's timer, and Get vsys
// raises the core's requirement notice. Every word comes from ViewLogic.js
// and every value from the service's published `detail`.
//
// A panel is built on summon and destroyed on hide, so its lifetime is one
// open: it runs `vsys --once --summary` once per open() and holds the
// clock at seconds while it lives (D041).
Item {
    id: root

    property var shell: null
    // The service's last derived state, null before it published one.
    readonly property var detail: shell === null || shell.status.values.detail === undefined ? null : shell.status.values.detail
    readonly property bool vsysMissing: shell === null || shell.requirements.missing.indexOf("vsys") !== -1
    readonly property real now: Time.now.getTime()
    readonly property var setupButton: detail === null ? null : View.setup(detail, vsysMissing)
    readonly property var footerLink: View.link(vsysMissing, setupButton)
    readonly property var memory: detail === null ? null : View.meter(detail.memory)
    // The last summary's line, { text, tone }, or null while none was read.
    property var summary: null
    // Why the last press did not hand off, "" when it did or before one.
    property string problem: ""

    function open(payloadJson) {
        problem = "";
        Time.holdSeconds(root, true);
        // A new run drops the last line, so a run that fails shows none
        // rather than an earlier verdict.
        if (!vsysMissing && !summaryRun.running) {
            summary = null;
            summaryRun.completion = null;
            summaryRun.running = true;
        }
    }
    function close() { Time.holdSeconds(root, false); }
    Component.onDestruction: Time.holdSeconds(root, false)

    // Do ACTION, one of View.setup's or View.link's; answers the
    // capability's reply. A press that handed off closes the flyout.
    function press(action) {
        let reply;
        switch (action) {
        case "open": reply = shell.tui.run("vsys"); break;
        case "setup": reply = shell.tui.run("setup"); break;
        case "start": reply = shell.run.detached(View.START_ARGV); break;
        case "get-vsys": reply = shell.requirements.offer(["vsys"]); break;
        default: throw new Error("agent-warden: action=" + JSON.stringify(action) + " unknown");
        }
        problem = View.refusal(reply);
        if (problem === "") shell.surfaces.hide("panel");
        else console.warn("agent-warden: action=" + action + " " + reply);
        return reply;
    }

    // One `vsys --once --summary` per open. A run that failed or printed
    // what this plugin cannot read is logged and shows no line.
    Process {
        id: summaryRun
        // The run's exit, { code, status }, null until `exited` arrives: a
        // command that fails to start emits `runningChanged` alone
        // (docs/architecture/runtime-qml.md).
        property var completion: null

        command: ["vsys", "--once", "--summary"]
        stdout: StdioCollector { id: summaryOut }
        stderr: StdioCollector { id: summaryErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (completion === null || completion.code !== 0 || completion.status !== 0) {
                console.warn("agent-warden: summary=failed " + JSON.stringify(completion) + " " + summaryErr.text.trim().split("\n")[0]);
                return;
            }
            const read = View.readSummary(summaryOut.text);
            if (read.kind === "read") root.summary = View.summaryLine(read);
            else console.warn("agent-warden: summary=unreadable cause=" + read.cause);
        }
    }

    implicitWidth: Theme.size.panel.md
    implicitHeight: layout.implicitHeight

    Surface {
        anchors.fill: parent
    }

    // One inset box: the heading and its sentence, the body's blocks
    // `stack.group` apart, and a footer with the check's time and the link.
    Pane {
        id: layout
        anchors.fill: parent
        container: "popover"
        fitToContent: true
        maximumHeight: Theme.size.panel.maxHeight

        header: [
            Column {
                width: layout.contentWidth
                spacing: Theme.row.lineGap

                Label {
                    role: "h3"
                    text: "Agents"
                }

                Label {
                    role: "body"
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.detail === null ? "Agent Warden is starting." : View.sentence(root.detail, root.vsysMissing)
                }
            }
        ]

        Column {
            id: itemList
            width: layout.contentWidth
            visible: root.detail !== null && root.detail.items.length > 0
            // The model changes only with the detail; each row's words
            // follow the clock, so the rows are not rebuilt each second.
            // A row takes no click, so it draws no box and its text sits
            // on the content edge.
            Repeater {
                model: root.detail === null ? [] : View.shownItems(root.detail)
                ListItem {
                    required property var modelData
                    readonly property var row: View.itemRow(modelData, root.now)
                    // The list, not `parent`, which is null while the
                    // repeater tears the row down.
                    width: itemList.width
                    leftPadding: 0
                    rightPadding: 0
                    hoverEnabled: false
                    iconName: row.icon
                    text: row.text
                    secondary: row.secondary
                }
            }
        }

        Column {
            width: layout.contentWidth
            spacing: Theme.row.lineGap
            visible: root.memory !== null
            ProgressBar {
                width: parent.width
                value: root.memory === null ? 0 : root.memory.value
            }
            Label {
                role: "hint"
                text: root.memory === null ? "" : root.memory.text
            }
        }

        Label {
            role: "hint"
            width: layout.contentWidth
            wrapMode: Text.Wrap
            visible: root.summary !== null && !root.vsysMissing
            text: root.summary === null ? "" : root.summary.text
            color: root.summary === null ? Theme.color.textFaint : Theme.badge.tone[root.summary.tone].foreground
        }

        Button {
            visible: root.setupButton !== null
            variant: "primary"
            text: root.setupButton === null ? "" : root.setupButton.label
            onClicked: root.press(root.setupButton.action)
        }

        Label {
            role: "hint"
            width: layout.contentWidth
            wrapMode: Text.Wrap
            visible: text !== ""
            text: root.problem
            color: Theme.color.danger
        }

        footer: [
            Column {
                width: layout.contentWidth
                spacing: Theme.stack.group

                Divider { width: parent.width }

                Item {
                    width: parent.width
                    implicitHeight: Math.max(checkedLabel.implicitHeight, linkButton.implicitHeight)

                    Label {
                        id: checkedLabel
                        role: "hint"
                        anchors.left: parent.left
                        y: topForCapCenter(parent.height)
                        text: root.detail === null ? "" : View.checked(root.detail, root.now)
                    }
                    Button {
                        id: linkButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.footerLink !== null
                        variant: "tertiary"
                        text: root.footerLink === null ? "" : root.footerLink.label
                        onClicked: root.press(root.footerLink.action)
                    }
                }
            }
        ]
    }
}
