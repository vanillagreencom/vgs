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
// every change; it runs nothing itself. Tab moves through the controls in
// reading order; the arrows move a slider and a closed Select.
FocusScope {
    id: root

    property var shell: null
    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var list: values.displays === undefined ? ({ state: "pending", items: [] }) : values.displays
    readonly property var assignments: values.assignments === undefined ? ({ entries: [], error: null }) : values.assignments
    readonly property var stale: assignments.entries.filter(e => e.state === "stale")
    readonly property var outputs: shell === null || shell.monitors.outputs === null ? [] : shell.monitors.outputs
    // One choice per output identifier, as an assignment names it; the
    // first entry is no choice.
    readonly property var screenChoices: {
        const out = [{ label: "Choose a screen", value: "" }];
        for (const o of outputs) {
            const known = out.find(c => c.value === o.identifier);
            const product = (o.make + " " + o.model).trim();
            if (known !== undefined) known.names.push(o.name);
            else out.push({ names: [o.name], product: product, value: o.identifier });
        }
        for (const choice of out) {
            if (choice.names === undefined) continue;
            choice.label = choice.names.join(" + ") + (choice.product === "" ? "" : ": " + choice.product);
        }
        return out;
    }
    readonly property var accessKeys: ["appleAccess", "ddcAccess", "ddcTool", "backlightTool"]
    // The refusal the last step was answered with, "" for none.
    property string problem: ""
    readonly property Item initialFocus: displaysColumn.firstFocus !== null ? displaysColumn.firstFocus : linkSwitch

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
    function setLinked(linked) { return answered(shell.configure.set("linked", linked)); }
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

    function badgeTone(tone) {
        switch (tone) {
        case "ok": return "success";
        case "info": return "info";
        case "warning": return "warning";
        case "danger": return "danger";
        }
        throw new Error("displays pane: tone " + JSON.stringify(tone) + " is not one of ok, info, warning, danger");
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
                        readonly property bool placeable: modelData.outputs.length === 0 || modelData.assigned
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
                visible: root.list.items.length === 0
                role: "hint"
                text: root.list.state === "failed" ? "Displays could not be read." : root.list.state === "pending" ? "Reading displays" : "No display with brightness control"
                wrapMode: Text.Wrap
            }

            FormRow {
                width: parent.width
                label: "Link displays"
                Switch {
                    id: linkSwitch
                    size: "sm"
                    checked: root.shell !== null && root.shell.settings.linked === true
                    Accessible.name: "Link displays"
                    onToggled: root.setLinked(checked)
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

        Column {
            id: staleColumn
            width: parent.width
            spacing: Theme.stack.group
            visible: root.stale.length > 0 || root.assignments.error !== null

            SectionHeader {
                width: parent.width
                text: "Saved choices"
                description: root.assignments.error !== null ? "The saved choices could not be read. Your next choice replaces them." : "These displays or screens are not connected now."
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
                model: root.accessKeys

                FormRow {
                    id: accessRow
                    required property string modelData
                    readonly property var reading: root.values[modelData] === undefined ? ({ tone: "info", text: "", action: false }) : root.values[modelData]
                    readonly property var declared: root.shell === null ? ({ label: "", action: { label: "" } }) : root.shell.manifest.status[modelData]
                    width: accessColumn.width
                    visible: root.values[modelData] !== undefined
                    label: declared.label

                    Row {
                        width: parent.width
                        spacing: Theme.stack.inline

                        Badge {
                            anchors.verticalCenter: parent.verticalCenter
                            text: accessRow.reading.text
                            tone: root.badgeTone(accessRow.reading.tone)
                        }
                        Button {
                            visible: accessRow.reading.action === true
                            anchors.verticalCenter: parent.verticalCenter
                            variant: "secondary"
                            size: "sm"
                            text: accessRow.declared.action.label
                            onClicked: root.runAction(accessRow.modelData)
                        }
                    }
                }
            }
        }
    }
}
