import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as Logic

// The workspace icons of the sender one NotificationLogic rule reads, taken
// with no credentials from that sender's own client, read-only: its
// workspace list, and the icon images its disk cache already holds. The
// list is read when the service starts, and again when a notification names
// a workspace it lacks or holds with no icon, at most once per
// NotificationLogic.WORKSPACE_RELOAD_GAP. images.sh copies each icon out of
// the cache into this rule's own directory under the cache home, which it
// empties first, so the directory holds at most two icons for each of
// NotificationLogic.WORKSPACES_MAX workspaces. A workspace with no icon
// keeps its name as text on the card.
Scope {
    id: source

    required property string modelData
    readonly property string ruleId: modelData
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vgs/notifications/workspaces/" + ruleId
    readonly property string script: String(Qt.resolvedUrl("images.sh")).replace(/^file:\/\//, "")

    // Workspace name, case folded -> its icon's file URL, or "" for none
    // (NotificationLogic.workspaceIconMap).
    property var icons: ({})
    // A read of the list and its copies is under way; `loadedAt` is when the
    // last one began. The view reads the list once as it is built.
    property bool loading: true
    property real loadedAt: Date.now()
    // The workspaces the list named, while the helper copies their icons.
    property var listed: []

    function workspaces() {
        return Logic.enricherById(ruleId).workspaces;
    }

    function iconFor(workspace) {
        const key = String(workspace || "").trim().toLowerCase();
        return Logic.hasOwn(icons, key) ? icons[key] : "";
    }

    // A notification named `workspace`: read the list again when it may now
    // hold that workspace's icon.
    function want(workspace) {
        if (loading || !Logic.workspaceReload(icons, workspace, loadedAt, Date.now())) return;
        load();
    }

    function load() {
        loading = true;
        loadedAt = Date.now();
        Qt.callLater(() => index.reload());
    }

    function finish(map) {
        icons = map;
        listed = [];
        loading = false;
    }

    FileView {
        id: index
        path: source.configHome + "/" + source.workspaces().index
        watchChanges: false
        printErrors: false
        onLoaded: source.copy(text())
        // No list is no sender client on this machine, and no icons.
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.warn("notifications: workspace list unreadable: file=" + path + " error=" + error);
            source.finish({});
        }
    }

    function copy(text) {
        const read = workspaces().read(text);
        if (!read.ok) {
            console.warn("notifications: workspace list refused: file=" + index.path + " reason=" + read.error);
            finish({});
            return;
        }
        if (read.skipped > 0) console.warn("notifications: workspace list entries skipped: file=" + index.path + " count=" + read.skipped);
        listed = read.workspaces;
        const argv = ["bash", script, "cached", configHome + "/" + workspaces().cache, dir];
        for (const pair of Logic.workspaceCopies(read.workspaces, dir)) argv.push(pair.to, pair.url);
        helper.command = argv;
        helper.running = true;
    }

    Process {
        id: helper
        property var completion: null
        stdout: StdioCollector { id: helperOut }
        stderr: StdioCollector { id: helperErr }
        onExited: (code, status) => { completion = { code: code }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const copied = [];
            if (done === null || done.code !== 0) {
                const first = String(helperErr.text || "").split("\n").find(l => l.indexOf("notifications-images: ") === 0);
                console.error(first !== undefined ? first : "notifications-images: " + (done === null ? "start=failed" : "exit=" + done.code) + " verb=cached");
            } else {
                for (const line of String(helperOut.text || "").split("\n"))
                    if (line.indexOf("copied ") === 0) copied.push(line.slice(7));
            }
            source.finish(Logic.workspaceIconMap(source.listed, source.dir, copied));
        }
    }
}
