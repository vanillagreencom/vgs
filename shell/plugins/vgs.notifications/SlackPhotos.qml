import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationLogic.js" as Logic

// Optional Slack Web API photos. The helper reads one Slack user token per
// workspace, and the single-workspace token, from libsecret, then refreshes
// each team's part of this plugin's cache under XDG cache at most once per
// day. A missing token leaves that team out and prints nothing.
// token-status.sh reports whether each token is stored, never reading it;
// `tokenStates` holds its answer, account -> a `presence` status value,
// and null before the first. Both run once `workspaces`, Slack's own list,
// has been read, again when the list names other workspaces, the probe
// after each helper run, and the helper at
// NotificationLogic.slackPhotoDelay.
Scope {
    id: photos

    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vgs/notifications/slack-photos"
    readonly property string script: String(Qt.resolvedUrl("slack-photos.js")).replace(/^file:\/\//, "")
    readonly property string tokenScript: String(Qt.resolvedUrl("token-status.sh")).replace(/^file:\/\//, "")
    // Slack's workspace list as NotificationLogic.slackWorkspaces reads it,
    // and whether it has been read once.
    property var workspaces: []
    property bool listed: false
    readonly property string teamKey: workspaces.map(w => w.id).join(",")
    property var teams: []
    property bool loading: false
    // A run asked for while one runs runs once it ends.
    property bool loadPending: false
    property string lastProblem: ""
    property var tokenStates: null
    property bool tokenCheckPending: false
    // The team ids the running probe was asked about.
    property var probed: []

    function teamIds() {
        return workspaces.map(w => w.id);
    }

    function start() {
        if (!listed) return;
        checkToken();
        load();
    }

    // The list's first read changes both at once; one start follows.
    onListedChanged: Qt.callLater(start)
    onTeamKeyChanged: Qt.callLater(start)

    function checkToken() {
        if (tokenProbe.running) { tokenCheckPending = true; return; }
        probed = teamIds();
        tokenProbe.command = ["bash", tokenScript].concat(probed);
        tokenProbe.running = true;
    }

    function load() {
        if (loading) { loadPending = true; return; }
        retry.stop();
        loading = true;
        helper.command = ["node", script, "refresh", dir].concat(teamIds());
        helper.running = true;
    }

    function schedule(ms) {
        retry.interval = Math.max(1000, ms);
        retry.restart();
    }

    function problemLines() {
        return String(helperErr.text || "").split("\n").filter(l => l.indexOf("notifications-slack-photos: ") === 0);
    }

    // The helper's problem lines, logged when they differ from the last
    // run's, so a repeated failure is logged once.
    function logProblem(line) {
        if (line === "" || line === lastProblem) return;
        lastProblem = line;
        for (const one of line.split("\n")) console.warn(one);
    }

    function logRecovery(read) {
        if (lastProblem === "" || read.stale || read.downloadFailed > 0) return;
        lastProblem = "";
        console.warn("notifications-slack-photos: recovered");
    }

    function faceImages(enrichment, carriedImage, workspace) {
        return Logic.slackFaceImages(enrichment, teams, carriedImage, workspace);
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
            const lines = photos.problemLines().join("\n");
            const read = Logic.slackPhotos(helperOut.text);
            if (!read.ok) {
                photos.logProblem(lines !== "" ? lines : "notifications-slack-photos: " + (done === null ? "start=failed" : done.code !== 0 ? "exit=" + done.code : "cache refused: reason=" + read.error));
                photos.teams = [];
            } else {
                if (done === null || done.code !== 0) photos.logProblem(lines !== "" ? lines : "notifications-slack-photos: " + (done === null ? "start=failed" : "exit=" + done.code));
                else if (lines !== "") photos.logProblem(lines);
                else photos.logRecovery(read);
                photos.teams = read.teams;
            }
            if (photos.loadPending) {
                photos.loadPending = false;
                photos.load();
                return;
            }
            photos.schedule(Logic.slackPhotoDelay(read, photos.workspaces, Date.now()));
        }
    }

    // The token probe. A run that fails, or prints what the probe never
    // prints, is logged and read as every account `unavailable`: the store
    // could not be asked, which is not a stored token and not a missing one.
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
            const read = done !== null && done.code === 0 ? Logic.slackTokenStates(tokenOut.text) : { ok: false, error: "" };
            if (read.ok) photos.tokenStates = read.states;
            else {
                const line = String(tokenErr.text || "").split("\n")[0];
                console.warn("notifications-token-status: probe=failed " + (done === null ? "start=failed" : done.code !== 0 ? "exit=" + done.code : "output refused: reason=" + read.error) + (line !== "" ? " stderr=" + line : ""));
                const states = { slack: "unavailable" };
                for (const id of photos.probed) states["slack:" + id] = "unavailable";
                photos.tokenStates = states;
            }
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
}
