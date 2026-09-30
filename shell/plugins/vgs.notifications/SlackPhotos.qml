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
// has been read, again when the list names other workspaces and after each
// token write the core ends (`secretRevision`), the probe after each helper
// run, and the helper at NotificationLogic.slackPhotoDelay.
//
// With `emojiEnabled`, the same run builds each listed team's custom emoji
// from Slack's disk cache and emoji.list (slack-emoji.js), and the shell
// takes the run's map in one swap: `emoji` becomes a new object, which is
// what every card's binding follows, so the cards on screen resolve their
// shortcodes again once. A card's lookup is an own-property read with no
// I/O, and no notification starts a run. A run is stamped with the team
// set and the setting it was asked with, and a run asked with others does
// not swap its emoji in.
Scope {
    id: photos

    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vgs/notifications/slack-photos"
    readonly property string script: String(Qt.resolvedUrl("slack-photos.js")).replace(/^file:\/\//, "")
    readonly property string tokenScript: String(Qt.resolvedUrl("token-status.sh")).replace(/^file:\/\//, "")
    // Slack's disk cache, the one WorkspaceIcons reads its icons from.
    readonly property string slackCache: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/" + Logic.enricherById("slack").workspaces.cache
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
    property bool emojiEnabled: false
    // The count of token writes the core ended for this plugin, the
    // `secrets` capability's revision: a Connect or Disconnect on the
    // Settings page probes and loads again at once, rather than at the next
    // retry.
    property int secretRevision: 0
    // Team id -> name -> file URL (NotificationLogic.slackEmojiLookups).
    property var emoji: Logic.slackEmojiLookups([], dir)
    // The emoji list last swapped in, as JSON, and how many swaps and
    // helper runs there have been, which `status` reports.
    property string emojiKey: "[]"
    property int emojiSwaps: 0
    property int runs: 0
    readonly property string generation: teamKey + "|" + emojiEnabled

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
    onSecretRevisionChanged: Qt.callLater(start)
    // Off clears the cards' emoji at once; the run then empties the index.
    onEmojiEnabledChanged: {
        if (!emojiEnabled) swapEmoji([]);
        if (listed) Qt.callLater(load);
    }

    function swapEmoji(teams) {
        const key = JSON.stringify(teams);
        if (key === emojiKey) return;
        emoji = Logic.slackEmojiLookups(teams, dir);
        emojiKey = key;
        emojiSwaps += 1;
    }

    // The emoji of each team, counted, never named.
    function emojiCounts() {
        const out = {};
        for (const id of Object.keys(emoji)) out[id] = Object.keys(emoji[id]).length;
        return out;
    }

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
        runs += 1;
        helper.generation = generation;
        helper.command = ["node", script, "refresh", dir].concat(emojiEnabled ? ["--emoji", slackCache] : [], teamIds());
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
        property string generation: ""
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
                if (read.emoji !== null && helper.generation === photos.generation) photos.swapEmoji(read.emoji);
            }
            if (photos.loadPending) {
                photos.loadPending = false;
                photos.load();
                return;
            }
            photos.schedule(Logic.slackPhotoDelay(read, photos.workspaces, Date.now(), photos.emojiEnabled));
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
