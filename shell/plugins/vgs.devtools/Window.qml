import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Appearance.js" as Appearance
import "ViewLogic.js" as ViewLogic

// The Dev Tools window: the VGS section, with how VGS is installed and
// every missing requirement of VGS and its enabled plugins, then every
// section of the catalog and the global mise tools no row declares, each
// row with its state and its actions. It draws the `catalog` the service
// publishes as plugin status and runs nothing itself: an action opens the
// plugin's floating TUI for that row, the Update group's entry for VGS, or
// the core's requirement notice for a missing requirement, and the service
// lists again when the run ends or the core's scan finds another set. The switch at the end
// writes the writeLaunchers setting. The window host builds it on summon as
// a Hyprland window titled Dev Tools, which Hyprland floats, centres, frames
// and focuses like any other window, and destroys it when it is hidden or
// closed; Escape closes it through the host. It takes no payload. It asks
// to be `look.window.width` wide and `look.window.maxHeight` tall, less
// `look.window.gutter` a side on a screen too small for that, read from the
// screen its `screens` capability gives. A window asks for its size once,
// when it maps, and the catalog may arrive after that, so the height does
// not follow the rows: they scroll, and fill whatever size the window has.
// Everything it draws itself reads `look`, the plugin's own table
// (Appearance.js, D023).
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation, and
    // again when the plugin's settings change.
    property var shell: null
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)
    // The screen the window opens on, whose size bounds the window's own.
    readonly property var screen: shell === null ? null : shell.screens.current
    readonly property var catalog: shell === null || shell.status.values.catalog === undefined ? null : shell.status.values.catalog
    readonly property bool writeLaunchers: shell !== null && shell.settings.writeLaunchers === true
    readonly property var tuiState: shell === null ? ({}) : shell.tui.state
    readonly property string updateKey: shell === null ? "" : ViewLogic.updateEntry(shell.tui.entries)
    readonly property var drawn: ViewLogic.sections(catalog, updateKey, writeLaunchers)
    // The refusal the last action was answered with, "" for none.
    property string problem: ""

    function open(payloadJson) {
        if (look === null) throw new Error("devtools: refused: appearance");
        problem = "";
    }
    function close() {}

    // Run ACTION of ROW, a ViewLogic row, with CHANNEL, the Select's
    // choice or ""; answers the capability's reply.
    function act(row, action, channel) {
        let reply;
        switch (action.kind) {
        case "verb":
            reply = shell.tui.run(action.verb, ViewLogic.verbArgs(action.verb, row, channel));
            break;
        case "doctor":
            reply = shell.doctor.offer(row.requirement.owner, [row.requirement.command]);
            break;
        case "entry":
            reply = shell.tui.open(action.verb);
            break;
        default:
            throw new Error("devtools: action kind " + JSON.stringify(action.kind) + " is not one of verb, doctor, entry");
        }
        problem = ViewLogic.replyLine(reply);
        if (problem !== "") console.warn("devtools window: " + reply);
        return reply;
    }

    implicitWidth: screen === null ? look.window.width : Math.floor(Math.min(look.window.width, screen.width - 2 * look.window.gutter))
    implicitHeight: screen === null ? look.window.maxHeight : Math.floor(Math.min(look.window.maxHeight, screen.height - 2 * look.window.gutter))

    ScrollArea {
        anchors.fill: parent
        anchors.margins: root.look.window.padding

        Column {
            id: content
            width: parent.width
            spacing: root.look.window.gap

            Column {
                x: root.look.row.paddingX
                width: parent.width - 2 * root.look.row.paddingX
                spacing: root.look.row.lineGap

                Label {
                    role: "h3"
                    text: "Dev Tools"
                }
                Label {
                    width: parent.width
                    role: "hint"
                    text: ViewLogic.summary(root.catalog)
                    elide: Text.ElideRight
                }
                Repeater {
                    model: ViewLogic.runningLines(root.tuiState)
                    Row {
                        required property string modelData
                        spacing: root.look.row.lineGap
                        Spinner { anchors.verticalCenter: parent.verticalCenter }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            role: "hint"
                            text: parent.modelData
                        }
                    }
                }
                Label {
                    width: parent.width
                    role: "hint"
                    visible: text !== ""
                    text: root.problem
                    wrapMode: Text.Wrap
                }
            }

            Repeater {
                model: ScriptModel {
                    values: root.drawn
                    objectProp: "key"
                }

                Column {
                    id: section
                    required property var modelData
                    width: content.width
                    topPadding: root.look.window.sectionGap
                    spacing: root.look.window.gap

                    SectionHeader {
                        width: parent.width
                        text: section.modelData.title
                        description: section.modelData.description
                        leftPadding: root.look.row.paddingX
                        rightPadding: root.look.row.paddingX
                    }
                    Repeater {
                        model: section.modelData.lines
                        Label {
                            required property string modelData
                            x: root.look.row.paddingX
                            width: section.width - 2 * root.look.row.paddingX
                            role: "hint"
                            text: modelData
                            wrapMode: Text.Wrap
                        }
                    }
                    Repeater {
                        model: ScriptModel {
                            values: section.modelData.rows
                            objectProp: "key"
                        }
                        ToolRow {
                            required property var modelData
                            width: section.width
                            row: modelData
                            look: root.look
                            onActed: (action, channel) => root.act(modelData, action, channel)
                        }
                    }
                }
            }

            Column {
                x: root.look.row.paddingX
                width: parent.width - 2 * root.look.row.paddingX
                topPadding: root.look.window.sectionGap
                spacing: root.look.row.lineGap

                Switch {
                    text: "Write launchers"
                    checked: root.writeLaunchers
                    onToggled: {
                        const wanted = checked;
                        checked = Qt.binding(() => root.writeLaunchers);
                        const reply = root.shell.configure.set("writeLaunchers", wanted);
                        root.problem = reply === "ok" ? "" : reply;
                    }
                }
                Label {
                    width: parent.width
                    role: "hint"
                    text: "A launcher in ~/.local/bin installs its tool through mise on first run; VGS never touches a file it did not write"
                    wrapMode: Text.Wrap
                }
            }
        }
    }
}
