import QtQuick
// Publishes the Apple display step's state as status, as a section plugin
// does: the `system` capability's reading, with Allow offered while the
// step is needed or waits on the NixOS configuration.
Item {
    id: root
    property var shell: null
    readonly property var systemState: shell === null ? null : shell.system.state
    readonly property int systemRevision: shell === null ? -1 : shell.system.revision
    readonly property var statusValues: shell === null ? null : shell.status.values
    property string lastReply: ""

    onSystemStateChanged: publish()

    function publish() {
        if (systemState === null) return;
        const step = systemState["apple-displays"];
        lastReply = shell.status.set("apple", {
            tone: step.state === "ready" ? "ok" : "warning",
            text: step.state + " " + step.reason,
            action: step.state === "needed" || step.state === "nixos"
        });
    }
}
