import QtQuick

// Only the nested smoke installs this fixture. It retains asynchronous
// capability answers for readInstance without changing shipped readback.
Item {
    id: root
    property var shell: null
    property bool registered: false
    readonly property bool hostFocusControl: false
    property var keys: null
    readonly property var translation: keys === null || keys.translation === undefined ? null : keys.translation
    property var observation: null
    property int keyAnswers: 0
    property int observationAnswers: 0

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("keys", text => {
            root.keys = null;
            root.shell.hyprland.resolveKeys(JSON.parse(text), value => {
                root.keys = value;
                root.keyAnswers += 1;
            });
            return "ok";
        });
        shell.ipc.handle("observe", text => {
            root.observation = null;
            root.shell.compositor.observeInput(JSON.parse(text), value => {
                root.observation = value;
                root.observationAnswers += 1;
            });
            return "ok";
        });
    }
}
