import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "UpdatesLogic.js" as Logic

// The Updates flyout: where updates stand, one row per source the service
// published with its count, the packages it lists when opened and its own
// Update when it has updates, then Update everything, and a footer with
// Refresh, the last check's time and the last run's log. It draws the
// status the service publishes and runs nothing itself: Refresh asks the
// service's `check` through the plugin's own IPC, and every update and the
// log open the plugin's floating TUIs (UpdatesLogic.tuiRequest). It is
// built on summon and destroyed on hide, and takes no payload.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation, and
    // again when the plugin's settings change.
    property var shell: null
    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var view: Logic.widgetView(values, false)
    readonly property var rows: Logic.panelRows(values)
    // The refusal the last action was answered with, "" for none.
    property string problem: ""

    function open(payloadJson) { problem = ""; }
    function close() {}

    // The time of MS in the locale's short format, with the date when
    // WITHDATE holds.
    function formatWhen(ms, withDate) {
        const when = new Date(ms);
        return withDate ? when.toLocaleString(Qt.locale(), Locale.ShortFormat) : when.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
    }

    // Open the TUI for ACTION (`all`, `source` with SOURCE, or `log`);
    // answers the capability's reply.
    function run(action, source) {
        const request = Logic.tuiRequest(action, source);
        return answered(shell.tui.run(request.name, request.args));
    }

    // Ask the service for a check now; answers its reply, `started` or
    // `queued`.
    function refresh() { return answered(shell.ipc.call("check", "")); }

    function answered(reply) {
        problem = Logic.replyLine(reply);
        if (problem !== "") console.warn("updates panel: " + reply);
        return reply;
    }

    implicitWidth: Theme.size.panel.lg
    implicitHeight: Math.min(sections.implicitHeight + 2 * Theme.surface.padding, Theme.size.panel.maxHeight)

    Surface {
        anchors.fill: parent

        ScrollArea {
            anchors.fill: parent
            anchors.margins: Theme.surface.padding

            Column {
                id: sections
                width: parent.width
                spacing: Theme.space.xs

                Column {
                    x: Theme.row.paddingX
                    width: parent.width - 2 * Theme.row.paddingX
                    spacing: Theme.row.lineGap

                    Label {
                        role: "h3"
                        text: "Updates"
                    }
                    Row {
                        width: parent.width
                        spacing: Theme.row.lineGap
                        Spinner {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.view.spinning
                        }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - (root.view.spinning ? Theme.spinner.size + parent.spacing : 0)
                            role: "hint"
                            text: Logic.summaryText(root.values)
                            color: root.view.tone === "warning" ? Theme.color.warning : Theme.color.textMuted
                            wrapMode: Text.Wrap
                        }
                    }
                    Label {
                        width: parent.width
                        role: "hint"
                        visible: text !== ""
                        text: root.problem
                        color: Theme.color.danger
                        wrapMode: Text.Wrap
                    }
                }

                Repeater {
                    model: ScriptModel {
                        values: root.rows
                        objectProp: "key"
                    }

                    Disclosure {
                        id: source
                        required property var modelData
                        // The column, not `parent`, which is null while the
                        // repeater tears the row down.
                        width: sections.width
                        text: modelData.label
                        secondary: modelData.secondary
                        iconName: modelData.icon
                        expandable: modelData.lines.length > 0 || modelData.more !== ""
                        trailing: [
                            Badge {
                                anchors.verticalCenter: parent.verticalCenter
                                text: source.modelData.badge
                                tone: source.modelData.badgeTone
                            },
                            Button {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: source.modelData.updatable
                                variant: "secondary"
                                size: "sm"
                                text: "Update"
                                onClicked: root.run("source", source.modelData.source)
                            }
                        ]

                        Repeater {
                            model: source.modelData.lines
                            Label {
                                required property string modelData
                                x: Theme.row.paddingX
                                width: source.width - 2 * Theme.row.paddingX
                                role: "itemCode"
                                text: modelData
                                elide: Text.ElideRight
                            }
                        }
                        Label {
                            x: Theme.row.paddingX
                            width: source.width - 2 * Theme.row.paddingX
                            visible: text !== ""
                            role: "hint"
                            text: source.modelData.more
                        }
                    }
                }

                Label {
                    x: Theme.row.paddingX
                    width: parent.width - 2 * Theme.row.paddingX
                    visible: root.rows.length === 0
                    role: "hint"
                    text: "No check has listed a source yet"
                    wrapMode: Text.Wrap
                }

                Item {
                    x: Theme.row.paddingX
                    width: parent.width - 2 * Theme.row.paddingX
                    height: everything.implicitHeight + 2 * Theme.space.xs

                    Button {
                        id: everything
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        variant: "primary"
                        text: "Update everything"
                        iconName: "download"
                        onClicked: root.run("all")
                    }
                }

                Divider { width: parent.width }

                Item {
                    x: Theme.row.paddingX
                    width: parent.width - 2 * Theme.row.paddingX
                    height: Math.max(refreshButton.implicitHeight, logButton.implicitHeight)

                    Button {
                        id: refreshButton
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        variant: "tertiary"
                        size: "sm"
                        text: "Refresh"
                        iconName: "refresh-cw"
                        onClicked: root.refresh()
                    }
                    Label {
                        anchors.left: refreshButton.right
                        anchors.right: logButton.left
                        anchors.margins: Theme.space.sm
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignHCenter
                        role: "hint"
                        text: Logic.checkedText(root.values.lastCheck, Time.now.getTime(), root.formatWhen)
                        elide: Text.ElideRight
                    }
                    Button {
                        id: logButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        variant: "tertiary"
                        size: "sm"
                        text: "Open last log"
                        iconName: "scroll-text"
                        onClicked: root.run("log")
                    }
                }
            }
        }
    }
}
