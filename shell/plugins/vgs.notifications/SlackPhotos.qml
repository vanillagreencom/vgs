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
    readonly property int retryMs: 15 * 60 * 1000
    readonly property int dailyMs: 24 * 60 * 60 * 1000
    property var teams: []
    property bool loading: false
    property string lastProblem: ""

    function load() {
        if (loading) return;
        retry.stop();
        loading = true;
        helper.command = ["node", script, "refresh", dir];
        helper.running = true;
    }

    function schedule(ms) {
        retry.interval = Math.max(1000, ms);
        retry.restart();
    }

    function problemLine() {
        return String(helperErr.text || "").split("\n").find(l => l.indexOf("notifications-slack-photos: ") === 0) || "";
    }

    function logProblem(line) {
        if (line === "" || line === lastProblem) return;
        lastProblem = line;
        console.warn(line);
    }

    function logRecovery(read) {
        if (lastProblem === "" || read.stale || read.downloadFailed > 0) return;
        lastProblem = "";
        console.warn("notifications-slack-photos: recovered");
    }

    function delayFor(read) {
        if (read.status !== "loaded" || read.stale || read.downloadFailed > 0) return retryMs;
        const due = (read.generatedAt > 0 ? read.generatedAt : Date.now()) + dailyMs;
        return Math.max(1000, due - Date.now());
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
            const line = photos.problemLine();
            const read = Logic.slackPhotos(helperOut.text);
            if (!read.ok) {
                photos.logProblem(line !== "" ? line : "notifications-slack-photos: " + (done === null ? "start=failed" : done.code !== 0 ? "exit=" + done.code : "cache refused: reason=" + read.error));
                photos.teams = [];
                photos.schedule(photos.retryMs);
                return;
            }
            if (done === null || done.code !== 0) photos.logProblem(line !== "" ? line : "notifications-slack-photos: " + (done === null ? "start=failed" : "exit=" + done.code));
            else if (line !== "") photos.logProblem(line);
            else photos.logRecovery(read);
            photos.teams = read.teams;
            photos.schedule(photos.delayFor(read));
        }
    }

    Timer {
        id: retry
        repeat: false
        onTriggered: photos.load()
    }

    Component.onCompleted: load()
}
