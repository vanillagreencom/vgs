import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as Logic

// Optional Slack Web API photos. The helper reads the Slack user token from
// libsecret, then refreshes this plugin's cache under XDG cache at most
// once per day. A missing token returns an empty map and prints nothing.
// token-status.sh reports whether the token is stored, never reading it,
// at start and after each helper run; `tokenState` holds its answer, a
// `presence` status value, and "" before the first.
Scope {
    id: photos

    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vgs/notifications/slack-photos"
    readonly property string script: String(Qt.resolvedUrl("slack-photos.js")).replace(/^file:\/\//, "")
    readonly property int retryMs: 15 * 60 * 1000
    readonly property int dailyMs: 24 * 60 * 60 * 1000
    property var teams: []
    property bool loading: false
    property string lastProblem: ""
    readonly property string tokenScript: String(Qt.resolvedUrl("token-status.sh")).replace(/^file:\/\//, "")
    property string tokenState: ""
    // A check asked for while one runs runs once it ends.
    property bool tokenCheckPending: false

    function checkToken() {
        if (tokenProbe.running) { tokenCheckPending = true; return; }
        tokenProbe.command = ["bash", tokenScript];
        tokenProbe.running = true;
    }

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
            photos.checkToken();
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

    // The token probe. A run that fails, or prints what the probe never
    // prints, is logged and read as `unavailable`: the store could not be
    // asked, which is not a stored token and not a missing one.
    Process {
        id: tokenProbe
        property var completion: null
        stdout: StdioCollector { id: tokenOut }
        stderr: StdioCollector { id: tokenErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const state = done !== null && done.code === 0 ? Logic.slackTokenState(tokenOut.text) : "";
            if (state === "") {
                const line = String(tokenErr.text || "").split("\n")[0];
                console.warn("notifications-token-status: probe=failed " + (done === null ? "start=failed" : "exit=" + done.code) + (line !== "" ? " stderr=" + line : ""));
            }
            photos.tokenState = state === "" ? "unavailable" : state;
            if (photos.tokenCheckPending) {
                photos.tokenCheckPending = false;
                photos.checkToken();
            }
        }
    }

    Timer {
        id: retry
        repeat: false
        onTriggered: photos.load()
    }

    Component.onCompleted: {
        checkToken();
        load();
    }
}
