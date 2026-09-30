import QtQuick
// Publishes the fixture's status: `token` present as soon as it starts,
// every other value on request. It reads its own values back like any
// other instance.
//   invoke set <key>=<json>  publishes one value; answers the reply
//   invoke detail            publishes `detail` as { items: [1, 2] }
//   invoke big               publishes a `detail` past the ceiling
//   invoke tamper            writes into the published values in place;
//                            answers them as JSON afterwards
Item {
    id: root
    property var shell: null
    property bool registered: false
    property string startReply: ""
    readonly property int statusRevision: shell === null ? -1 : shell.status.revision
    readonly property var statusValues: shell === null ? null : shell.status.values
    readonly property string configuredDevice: shell === null ? "" : shell.settings.device

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        startReply = shell.status.set("token", "present");
        shell.ipc.handle("set", arg => { const at = arg.indexOf("="); return root.shell.status.set(arg.slice(0, at), JSON.parse(arg.slice(at + 1))); });
        shell.ipc.handle("detail", () => root.shell.status.set("detail", { items: [1, 2] }));
        shell.ipc.handle("big", () => root.shell.status.set("detail", "x".repeat(70000)));
        shell.ipc.handle("tamper", () => {
            const values = root.shell.status.values;
            try { values.pending = 99; } catch (e) {}
            try { values.detail.items.push(9); } catch (e) {}
            try { values.fresh = 1; } catch (e) {}
            if (values.devices !== undefined) {
                try { values.devices[0].label = "changed"; } catch (e) {}
                try { values.devices.push({ label: "Extra", value: "extra" }); } catch (e) {}
            }
            return JSON.stringify(root.shell.status.values);
        });
    }
}
