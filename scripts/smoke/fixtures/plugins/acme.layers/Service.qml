import QtQuick

// Draws one passive layer through the `layers` capability. The content
// counts the presses that reach it and reports the screens it is built on;
// its input is two separate pads in the top-left corner, or the whole
// surface while `full` is set.
//   invoke draw        registers the layer; `ok` or the refusal
//   invoke undraw      runs the disposer; `ok` or `absent`
//   invoke redraw      runs the disposer and registers again in one call
//   invoke full <0|1>  sets whether the whole surface takes input
//   invoke pads <0|1|2> sets an empty list, one pad or both pads
//   invoke bad         shows something that is no component; the refusal
//   invoke bare        shows a component without `screen`, which the host
//                      does not build; unbare releases it
Item {
    id: root

    property var shell: null
    property var release: null
    property var bareRelease: null
    property bool full: false
    property int pads: 2
    property int presses: 0
    property int releases: 0
    property int leftPresses: 0
    property int rightPresses: 0
    readonly property var events: [presses, releases, leftPresses, rightPresses]
    // The screen every live copy of the content received, sorted, each
    // once; a copy on its way out can overlap its successor on a screen, so
    // copies are counted per screen.
    property var built: []
    property var copies: ({})
    property bool registered: false

    function note(name, add) {
        const next = Object.assign({}, copies);
        next[name] = (next[name] || 0) + (add ? 1 : -1);
        if (next[name] <= 0) delete next[name];
        copies = next;
        built = Object.keys(next).sort();
    }

    Component {
        id: content
        Item {
            id: layer
            property var screen: null
            readonly property string screenName: screen ? screen.name : ""
            readonly property bool inputAll: root !== null && root.full
            readonly property var inputItems: root === null || root.pads === 0 ? [] : root.pads === 1 ? [leftPad] : [leftPad, rightPad]
            property string noted: ""
            onScreenNameChanged: {
                if (screenName === "" || noted !== "") return;
                noted = screenName;
                root.note(noted, true);
            }
            Component.onDestruction: if (noted !== "") root.note(noted, false)

            MouseArea {
                anchors.fill: parent
                onPressed: mouse => {
                    root.presses += 1;
                    if (mouse.x >= leftPad.x && mouse.x < leftPad.x + leftPad.width && mouse.y < leftPad.height) root.leftPresses += 1;
                    if (mouse.x >= rightPad.x && mouse.x < rightPad.x + rightPad.width && mouse.y < rightPad.height) root.rightPresses += 1;
                }
                onReleased: root.releases += 1
            }
            Rectangle {
                id: leftPad
                width: 80
                height: 40
                color: "transparent"
            }
            Rectangle {
                id: rightPad
                x: 160
                width: 80
                height: 40
                color: "transparent"
            }
        }
    }

    Component { id: bare; Item {} }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("draw", () => {
            if (root.release !== null) return "held";
            try {
                root.release = root.shell.layers.show(content);
                return "ok";
            } catch (e) {
                return e.message;
            }
        });
        shell.ipc.handle("undraw", () => {
            if (root.release === null) return "absent";
            root.release();
            root.release = null;
            return "ok";
        });
        shell.ipc.handle("redraw", () => {
            if (root.release === null) return "absent";
            root.release();
            root.release = root.shell.layers.show(content);
            return "ok";
        });
        shell.ipc.handle("bare", () => {
            if (root.bareRelease !== null) return "held";
            root.bareRelease = root.shell.layers.show(bare);
            return "ok";
        });
        shell.ipc.handle("unbare", () => {
            if (root.bareRelease === null) return "absent";
            root.bareRelease();
            root.bareRelease = null;
            return "ok";
        });
        shell.ipc.handle("full", arg => { root.full = arg === "1"; return "ok"; });
        shell.ipc.handle("pads", arg => {
            if (arg !== "0" && arg !== "1" && arg !== "2") return "refused: pads";
            root.pads = Number(arg);
            return "ok";
        });
        shell.ipc.handle("bad", () => {
            try {
                root.shell.layers.show({});
                return "accepted";
            } catch (e) {
                return e.message;
            }
        });
    }
}
