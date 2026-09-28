import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The themes panel: every theme package the runner lists, each with its
// palette and its state, and a click that applies one. It is built on
// summon and destroyed on hide, so everything it shows is read from the
// theme capability on open: the list, and `last`, which the core keeps
// across instances, so a panel closed during an apply and reopened after
// it shows the result.
Item {
    id: root

    property var shell: null
    // The last list's packages, [] before it arrives or after it failed.
    property var packages: []
    // The last list's theme file: its state, its named package and whether
    // it is modified; null before the list arrives or after it failed.
    property var file: null
    // Why the last list failed, "" when it did not.
    property string listReason: ""
    // `shell.theme.last` as last read: the apply running and the last
    // result. The capability's member is not a binding, so the panel reads
    // it again whenever an answer arrives.
    property var last: ({ applying: null, result: null })
    // The package a click asked for and the refusal `apply` answered at
    // once, or null; shown on its row until the next click.
    property var refusal: null

    // The panel takes no payload; what a summoner passes is ignored.
    function open(payloadJson) { refresh(); }
    function close() {}

    // Read `last` and ask for the list. A list asked for while an apply
    // runs waits for it, so its answer is also when a running apply that
    // this instance did not start has finished.
    function refresh() {
        readLast();
        shell.theme.list(result => {
            root.listReason = result.reason === null ? "" : result.reason;
            root.packages = result.reason === null ? result.packages : [];
            root.file = result.file;
            root.readLast();
        });
    }

    function readLast() { last = shell.theme.last; }

    // Apply package `name`; answers the capability's reply.
    function apply(name) {
        const reply = shell.theme.apply(name, result => root.readLast());
        refusal = reply === "ok" ? null : { name: name, reply: reply };
        if (reply !== "ok") console.warn("themes panel: " + reply);
        readLast();
        return reply;
    }

    // The lines the row of package `name` shows for the last result: the
    // result's own refusal reason, then every target that did not land and
    // was not skipped, with its state and reason as the runner wrote them.
    // Only the states that mean nothing went wrong are named here, so a
    // state the runner adds is shown without a change to the panel.
    function resultLines(name) {
        const result = last.result;
        if (result === null || result.theme !== name) return [];
        const quiet = ["written", "unchanged", "skipped"];
        const lines = result.reason === null ? [] : [result.state + ": " + result.reason];
        for (const target of result.targets)
            if (quiet.indexOf(target.state) === -1)
                lines.push(target.name + " " + target.state + (target.reason === null ? "" : ": " + target.reason));
        return lines;
    }

    // Every line the row of package `name` shows: the last result's, then
    // the refusal a click on it was answered with.
    function linesFor(name) {
        const lines = resultLines(name);
        if (refusal !== null && refusal.name === name) lines.push(refusal.reply);
        return lines;
    }

    // The runner prints a new theme into the file before `done` runs, and
    // the shell's revision moves once it holds it: list again so the rows'
    // `current` and `modified` follow.
    Connections {
        target: Theme
        function onRevisionChanged() { root.refresh(); }
    }

    implicitWidth: Theme.size.panel.lg
    implicitHeight: Math.min(list.implicitHeight + 2 * Theme.surface.padding, Theme.size.panel.maxHeight)

    Surface {
        anchors.fill: parent

        ScrollArea {
            anchors.fill: parent
            anchors.margins: Theme.surface.padding

            Column {
                id: list
                width: parent.width
                spacing: Theme.space.xs

                SectionHeader {
                    text: "Themes"
                    description: "Every theme package; a click applies one to the shell and every application target"
                    leftPadding: Theme.row.paddingX
                    rightPadding: Theme.row.paddingX
                }

                Label {
                    role: "hint"
                    x: Theme.row.paddingX
                    width: parent.width - 2 * Theme.row.paddingX
                    visible: text !== ""
                    text: root.listReason === "" ? "" : "The theme list failed: " + root.listReason
                    color: Theme.color.danger
                    wrapMode: Text.Wrap
                }

                // A list asked for during an apply arrives after it, so a
                // panel opened while one runs names it here until then.
                Row {
                    x: Theme.row.paddingX
                    spacing: Theme.space.sm
                    visible: root.last.applying !== null
                    Spinner { anchors.verticalCenter: parent.verticalCenter }
                    Label {
                        role: "body"
                        text: "Applying " + root.last.applying
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Repeater {
                    model: ScriptModel {
                        values: root.packages.map(p => Object.assign({ key: p.source + "/" + p.name }, p))
                        objectProp: "key"
                    }

                    ThemeRow {
                        required property var modelData
                        // The list, not `parent`, which is null while the
                        // repeater tears the row down.
                        width: list.width
                        name: modelData.name
                        source: modelData.source
                        packageState: modelData.state
                        reason: modelData.reason === null ? "" : modelData.reason
                        swatch: modelData.state === "ok" ? root.shell.theme.swatch(modelData.name) : null
                        displayed: modelData.state === "ok" && modelData.name === Theme.name
                        modified: modelData.state === "ok" && modelData.current && root.file !== null && root.file.modified === true
                        applying: modelData.state === "ok" && root.last.applying === modelData.name
                        applicable: modelData.state === "ok" && root.last.applying === null
                        lines: modelData.state === "shadowed" ? [] : root.linesFor(modelData.name)
                        onActivated: root.apply(modelData.name)
                    }
                }
            }
        }
    }
}
