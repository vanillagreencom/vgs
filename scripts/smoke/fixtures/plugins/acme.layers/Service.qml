import QtQuick

// Draws one passive layer through the `layers` capability. The content
// counts the presses that reach it and reports the screens it is built on;
// its input is a fixed pad in the top-left corner, or the whole surface
// while `full` is set.
//   invoke draw        registers the layer; `ok` or the refusal
//   invoke undraw      runs the disposer; `ok` or `absent`
//   invoke full <0|1>  sets whether the whole surface takes input
//   invoke bad         shows something that is no component; the refusal
//   invoke bare        shows a component without `screen`, which the host
//                      does not build; unbare releases it
Item {
    id: root

    property var shell: null
    property var release: null
    property var bareRelease: null
    property bool full: false
    property int presses: 0
    // The screen every built copy of the content received, sorted.
    property var built: []
    property bool registered: false

    function note(name, add) {
        const next = built.filter(n => n !== name);
        if (add) next.push(name);
        built = next.sort();
    }

    Component {
        id: content
        Item {
            id: layer
            property var screen: null
            readonly property string screenName: screen ? screen.name : ""
            readonly property bool inputAll: root.full
            readonly property Item inputItem: pad
            property string noted: ""
            onScreenNameChanged: {
                if (screenName === "" || noted !== "") return;
                noted = screenName;
                root.note(noted, true);
            }
            Component.onDestruction: if (noted !== "") root.note(noted, false)

            MouseArea {
                anchors.fill: parent
                onPressed: root.presses += 1
            }
            Rectangle {
                id: pad
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
