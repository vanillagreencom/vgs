import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as Logic

// Optional Slack Web API photos. The helper reads the Slack user token from
// libsecret, then refreshes this plugin's cache under XDG cache at most
// once per day. A missing token returns an empty map and prints nothing.
Scope {
    id: photos

    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vgs/notifications/slack-photos"
    readonly property string script: String(Qt.resolvedUrl("slack-photos.js")).replace(/^file:\/\//, "")
    property var teams: []
    property bool loading: false

    function load() {
        if (loading) return;
        loading = true;
        helper.command = ["node", script, "refresh", dir];
        helper.running = true;
    }

    function faceImages(enrichment, carriedImage) {
        return Logic.slackFaceImages(enrichment, teams, carriedImage);
    }

    function workspaceIcon(workspace) {
        return Logic.slackWorkspaceIcon(teams, workspace);
    }

    Process {
        id: helper
        property var completion: null
        stdout: StdioCollector { id: helperOut }
        stderr: StdioCollector { id: helperErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            photos.loading = false;
            if (done === null || done.code !== 0) {
                const first = String(helperErr.text || "").split("\n").find(l => l.indexOf("notifications-slack-photos: ") === 0);
                console.warn(first !== undefined ? first : "notifications-slack-photos: " + (done === null ? "start=failed" : "exit=" + done.code));
                photos.teams = [];
                return;
            }
            const read = Logic.slackPhotos(helperOut.text);
            if (!read.ok) {
                console.warn("notifications-slack-photos: cache refused: reason=" + read.error);
                photos.teams = [];
                return;
            }
            photos.teams = read.teams;
        }
    }

    Component.onCompleted: load()
}
