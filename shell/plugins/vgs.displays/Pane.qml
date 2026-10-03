import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "DisplaysLogic.js" as Logic

// System → Displays: one row per display with its brightness or what keeps
// it from being ready; under a display the helper could not place, or one
// placed by the user's choice, the screen it shows on, picked from the
// outputs Hyprland reads, and Identify, which shows each screen's name and
// flashes that display; Link displays; the saved choices whose display or
// screen is gone, each with Forget; and the access entries the plugin's
// status publishes, each with its action while offered. The holder draws
// the title, the inset and the scrolling. It draws the status the service
// publishes and asks the service, or the core through `status.act`, for
// every change; it runs nothing itself. Each access entry's tone and
// offered action come from the core's status rows (`status.rows`). Tab moves through the controls in
// reading order; the arrows move a slider and a closed Select.
FocusScope {
    id: root

    property var shell: null
    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var list: values.displays === undefined ? ({ state: "pending", items: [] }) : values.displays
    readonly property var assignments: values.assignments === undefined ? ({ entries: [], error: null }) : values.assignments
    readonly property var stale: assignments.entries.filter(e => e.state === "stale")
    readonly property var outputs: shell === null || shell.monitors.outputs === null ? [] : shell.monitors.outputs
    readonly property var screenChoices: Logic.screenChoices(list.items, outputs)
    // The access entries the service has published, as the Settings page
    // draws them.
    readonly property var accessRows: shell === null ? [] : shell.status.rows.filter(r => r.group === "Access" && r.report === "reported")
    // The refusal the last step was answered with, "" for none.
    property string problem: ""
    readonly property Item initialFocus: displaysColumn.firstFocus !== null ? displaysColumn.firstFocus : linkRow.toggle

    function open(payloadJson) {
        problem = "";
    }
    function close() {}

    function answered(reply) {
        problem = Logic.replyText(reply);
        if (reply !== "ok") console.warn("displays pane: " + reply);
        return reply;
    }

    // Put DEVICE on the output OUTPUT names, "" to forget its choice;
    // answers the service's reply.
    function assign(device, output) { return answered(shell.ipc.call("assign", JSON.stringify({ device: device, output: output }))); }
    function identify(id) { return answered(shell.ipc.call("identify", id)); }
    function runAction(key) { return answered(shell.status.act(key)); }

    // The Select index of the choice that names IDENTIFIER, 0 for none.
    function choiceIndex(identifier) {
        for (let i = 0; i < screenChoices.length; i++) if (screenChoices[i].value === identifier) return i;
        return 0;
    }

    // The output identifier the applied choice of DEVICE names, "" for none.
    function chosenOutput(device) {
        const entry = assignments.entries.find(e => e.device === device && e.state === "applied");
        return entry === undefined ? "" : entry.output;
    }

    implicitWidth: Theme.size.window.width
    implicitHeight: content.implicitHeight
    focus: true

    Column {
        id: content
        width: root.width
        spacing: Theme.stack.section

        Column {
            width: parent.width
            spacing: Theme.stack.group

            SectionHeader {
                width: parent.width
                text: "Brightness"
                description: "Each display keeps its own level."
            }

            Column {
                id: displaysColumn
                property Item firstFocus: null
                width: parent.width
                spacing: Theme.stack.row

                Repeater {
                    model: ScriptModel {
                        values: root.list.items
                        objectProp: "id"
                    }

                    Column {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool placeable: Logic.placeable(modelData)
                        width: displaysColumn.width
                        spacing: Theme.stack.row

                        DisplayRow {
                            id: row
                            width: entry.width
                            shell: root.shell
                            display: entry.modelData
                            Component.onCompleted: if (entry.index === 0) displaysColumn.firstFocus = row.ready ? row.slider : null
                        }

                        FormRow {
                            width: entry.width
                            visible: entry.placeable
                            label: "Screen"
                            warning: entry.modelData.outputs.length === 0 ? "Not placed" : ""

                            Row {
                                width: parent.width
                                spacing: Theme.stack.inline

                                Select {
                                    id: screenSelect
                                    readonly property string chosen: root.chosenOutput(entry.modelData.device)
                                    width: parent.width - identifyButton.width - parent.spacing
                                    model: root.screenChoices
                                    textRole: "label"
                                    currentIndex: root.choiceIndex(chosen)
                                    Accessible.name: "Screen for " + entry.modelData.label
                                    // A new choice assigns currentIndex; the
                                    // binding comes back, so the choice the
                                    // service applies is the one shown.
                                    onActivated: index => {
                                        const output = root.screenChoices[index].value;
                                        if (output !== screenSelect.chosen) root.assign(entry.modelData.device, output);
                                        currentIndex = Qt.binding(() => root.choiceIndex(screenSelect.chosen));
                                    }
                                }
                                Button {
                                    id: identifyButton
                                    variant: "secondary"
                                    size: "sm"
                                    text: "Identify"
                                    iconName: "scan-eye"
                                    anchors.verticalCenter: parent.verticalCenter
                                    onClicked: root.identify(entry.modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            Label {
                width: parent.width
                visible: text !== ""
                role: "hint"
                text: Logic.listText(root.list.state, root.list.items.length)
                wrapMode: Text.Wrap
            }

            LinkRow {
                id: linkRow
                width: parent.width
                shell: root.shell
                onReplied: reply => root.answered(reply)
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

        Column {
            id: staleColumn
            width: parent.width
            spacing: Theme.stack.group
            visible: root.stale.length > 0 || root.assignments.error !== null

            SectionHeader {
                width: parent.width
                text: "Saved choices"
                description: Logic.savedChoicesText(root.assignments.error)
            }

            Repeater {
                model: ScriptModel {
                    values: root.stale
                    objectProp: "device"
                }

                FormRow {
                    required property var modelData
                    width: staleColumn.width
                    label: modelData.label

                    Row {
                        width: parent.width
                        spacing: Theme.stack.inline

                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - forgetButton.width - parent.spacing
                            role: "body"
                            text: modelData.output
                            elide: Text.ElideRight
                        }
                        Button {
                            id: forgetButton
                            variant: "secondary"
                            size: "sm"
                            text: "Forget"
                            onClicked: root.assign(modelData.device, "")
                        }
                    }
                }
            }
        }

        Column {
            id: accessColumn
            width: parent.width
            spacing: Theme.stack.group

            SectionHeader {
                width: parent.width
                text: "Access"
            }

            Repeater {
                model: ScriptModel {
                    values: root.accessRows
                    objectProp: "key"
                }

                FormRow {
                    id: accessRow
                    required property var modelData
                    width: accessColumn.width
                    label: modelData.label

                    Row {
                        width: parent.width
                        spacing: Theme.stack.inline

                        Badge {
                            anchors.verticalCenter: parent.verticalCenter
                            text: accessRow.modelData.value.text
                            tone: accessRow.modelData.tone
                        }
                        Button {
                            visible: accessRow.modelData.action !== null && accessRow.modelData.action.offered
                            anchors.verticalCenter: parent.verticalCenter
                            variant: "secondary"
                            size: "sm"
                            text: accessRow.modelData.action === null ? "" : accessRow.modelData.action.label
                            onClicked: root.runAction(accessRow.modelData.key)
                        }
                    }
                }
            }
        }
    }
}
