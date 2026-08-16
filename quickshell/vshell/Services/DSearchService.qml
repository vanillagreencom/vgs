pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

// Live launcher search. The historical name is retained so existing imports do
// not churn, but search is VGS-owned and backed by fd + ripgrep rather than the
// stale external dsearch index.
Singleton {
    id: root

    property bool supportsTypeFilter: true
    property bool versionChecked: true
    property int indexVersion: 3
    property string backendName: "fd + ripgrep"
    property bool fdAvailable: false
    property bool ripgrepAvailable: false
    // "pending" only while the FIRST probe is outstanding, then "ready", or
    // "retrying" from the first failure until the attempts are spent, then
    // "failed". The tool flags mean nothing outside "ready", so no caller may
    // report a tool as missing on their strength alone.
    //
    // Everything past the first failure is honestly "nobody knows" rather than
    // "checking", and that distinction buys exactly one thing: text search
    // resumes dispatching at the first failure instead of waiting out the
    // retries. An fd-backed name search stays refused until the probe settles,
    // because dispatching it unproven would silently buy the helper's full
    // directory walk. (Path completion and zoxide never waited on any of this:
    // backendStateFor answers the first before it reads a probe state, and no
    // probe covers the second.)
    //
    // A state that reached "ready" is never demoted by a later failure —
    // probeFailureOutcome.
    property string statusState: "pending"
    property string statusError: ""
    property int _statusAttempts: 0
    property int _statusGeneration: 0
    property bool _statusInFlight: false
    readonly property int _statusMaxAttempts: 3
    property var folderOpeners: [{ id: "default", label: I18n.tr("Preferred app"), icon: "open_in_new" }]
    property var _requestVersions: ({})
    property int _previewVersion: 0

    readonly property var log: Log.scoped("DSearchService")

    signal searchResultsReceived(var results)
    signal statsReceived(var stats)
    signal errorOccurred(string error)

    Component.onCompleted: {
        rediscover();
        refreshFolderOpeners();
    }

    Timer {
        id: statusRetryTimer
        repeat: false
        onTriggered: root._probeStatus()
    }

    // Single-flight. An episode owns the attempt budget from its first probe to
    // its last: starting a second one beside it would reset that budget, and
    // its callback would still be honoured after the first one answered — a
    // late failure overwriting a good detection.
    function rediscover() {
        if (_statusInFlight || statusRetryTimer.running)
            return;
        _statusAttempts = 0;
        _probeStatus();
    }

    // Re-probe unless the last answer is settled — a successful probe that found
    // every tool. A launcher open is when a transient failure gets its second
    // chance, and when the user who just installed fd on our own instruction
    // gets the answer that instruction promised. Single-flight bounds it to one
    // process per open, and the probe answer repaints the surface.
    function ensureStatus() {
        if (!probeSettled(_probeSnapshot()))
            rediscover();
    }

    function _probeStatus() {
        statusRetryTimer.stop();
        _statusAttempts += 1;
        _statusInFlight = true;
        const generation = ++_statusGeneration;
        Proc.runCommand("launcher-search-status", [Paths.vshellCli, "launcher-search", "status"], (stdout, exitCode, stderr) => {
            // A probe from a superseded episode answers for nobody: Proc keeps
            // the callback each launch was given, so without this a stale
            // failure lands on top of a fresh success.
            if (generation !== root._statusGeneration)
                return;
            root._statusInFlight = false;
            if (exitCode !== 0) {
                // Proc reports its own timeout as 124, which is the difference
                // between "the CLI answered with a failure" and "the CLI never
                // answered" — the operator needs to be told which.
                const detail = (stderr || "").trim();
                root._statusProbeFailed(exitCode === 124
                    ? "vshell launcher-search status timed out"
                    : "vshell launcher-search status exited " + exitCode + (detail ? ": " + detail : ""));
                return;
            }
            try {
                const status = JSON.parse(stdout);
                root.fdAvailable = !!status.fd;
                root.ripgrepAvailable = !!status.ripgrep;
                root.backendName = status.backend || "fd + ripgrep";
                root.statusError = "";
                root.statusState = "ready";
                root.statsReceived(status);
            } catch (e) {
                root._statusProbeFailed("vshell launcher-search status returned unreadable output");
            }
        }, 0, 3000);
    }

    function _statusProbeFailed(reason) {
        root.log.warn("launcher search status probe failed:", reason);
        const outcome = probeFailureOutcome(root.statusState, root._statusAttempts, root._statusMaxAttempts);
        if (outcome.publishReason)
            root.statusError = reason;
        root.statusState = outcome.state;
        if (outcome.retry) {
            // Bounded backoff, one budget per episode. One failed probe used to
            // leave search unanswerable for the life of the shell; retrying
            // forever would spawn a process a second for the same lifetime.
            //
            // Where there is no earlier answer, the state leaves "pending" on
            // the FIRST failure rather than at the end of the sequence: the
            // answer is already unknown, so the kinds that need no fd fallback
            // stop waiting out the ~12s the retries take.
            statusRetryTimer.interval = 1000 * root._statusAttempts;
            statusRetryTimer.start();
            return;
        }
        if (outcome.state === "failed")
            root.errorOccurred(I18n.tr("Unable to read launcher search status"));
    }

    // The single owner of "which tool does this search need, and do we have it".
    // Every gate, message and icon in the launcher surfaces reads these; the
    // functions are pure so scripts/test-launcher-search-gate.js runs this exact
    // source rather than a re-implementation.
    // BEGIN SEARCH BACKEND DECISION
    // The command a kind shells out to, or "" when no probed tool decides it.
    // Unlisted kinds are deliberately NOT fd's: "zoxide" belongs to the
    // launcher-zoxide feature and a typo must not inherit an answer.
    function backendCommandFor(kind) {
        switch (kind) {
        case "text":
            return "rg";
        case "files":
        case "folders":
        case "all":
            return "fd";
        }
        return "";
    }

    // The search kind a launcher file-search type asks for. The overview's "all"
    // type narrows to the name kind; only vgsMenu uses "zoxide".
    function kindForType(type) {
        switch (type) {
        case "dir":
            return "folders";
        case "text":
            return "text";
        case "zoxide":
            return "zoxide";
        }
        return "files";
    }

    // Folder queries that start at a path are answered by the helper's own
    // directory walk (bin/vshell-helper::_launcher_folder_path_hits), which runs
    // before fd is consulted, so path completion must not be gated on fd. The
    // condition mirrors that branch, "~" and "/" alike, and both forms arrive
    // from the overview: the BARE "/" is the launcher's own file-search trigger
    // and parseFileSearchPrefix consumes it, but the "/d " typed-type prefix
    // consumes only itself and passes a "/"-rooted query through intact.
    function pathCompletion(kind, query) {
        return kind === "folders" && /^[~/]/.test(String(query || "").trim());
    }

    // The one owner of "long enough to search", for every launcher surface that
    // decides whether to run a file search or to say why it did not. Each of
    // them used to carry the literal, and a threshold changed in all but one
    // leaves that one believing a search ran that never did.
    //
    // ADVISORY, not enforced: search() dispatches whatever it is given, because
    // vgsMenu's zoxide and explicit-folder-path legs deliberately run below the
    // threshold. It answers "would a plain name search run", nothing more.
    function queryIsDispatchable(query) {
        return String(query || "").trim().length >= 2;
    }

    // The same question asked for a KIND, which is what every launcher gate
    // actually wants: long enough, OR a path the helper completes without fd.
    // "~" and "/" are one character and are the first keystroke of a path, so
    // the length rule alone refuses the very capability pathCompletion exists to
    // allow — the surface then reports "type at least two characters" for a
    // query the helper can answer. Three predicates read this rather than
    // composing their own, so the gate, the retry and the message cannot
    // disagree about what a searchable query is.
    function queryIsSearchable(kind, query) {
        return queryIsDispatchable(query) || pathCompletion(kind, query);
    }

    // "checking" | "available" | "missing" | "unknown". `probe` carries the
    // status answer as { state, fd, ripgrep }. Unknown is never collapsed into
    // missing: telling a user to install a tool they already have, because a
    // probe could not run, is the same dead end as saying nothing.
    function backendStateFor(kind, query, probe) {
        if (pathCompletion(kind, query))
            return "available";
        const command = backendCommandFor(kind);
        if (command === "")
            return "unknown";
        const state = (probe || {}).state;
        if (state === "pending")
            return "checking";
        if (state !== "ready")
            return "unknown";
        return (command === "rg" ? !!(probe || {}).ripgrep : !!(probe || {}).fd) ? "available" : "missing";
    }

    // Whether the helper can answer this kind without its tool. Only fd-backed
    // kinds can: name search falls back to the helper's own directory walk,
    // while text search shells out to ripgrep and raises without it. Derived
    // from the one table, so a kind cannot be fd-backed here and something else
    // there.
    function helperHasFallback(kind) {
        return backendCommandFor(kind) === "fd";
    }

    // Whether a caller that will not accept the helper's directory walk may
    // dispatch. "available" always may — which is the arm a path completion
    // takes, since backendStateFor answers it before any probe state is read.
    // "unknown" may only where dispatching cannot silently buy that walk:
    // ripgrep fails fast with a real cause. A name search in the unknown state
    // is refused instead — a full walk of the roots per keystroke is the cost
    // the fd gate exists to avoid, and taking it because a probe could not run
    // would be taking it by accident.
    function dispatchAllowed(state, kind) {
        if (state === "available")
            return true;
        if (state !== "unknown")
            return false;
        return !helperHasFallback(kind);
    }

    // Whether the SERVICE itself refuses the call, as opposed to a caller
    // declining at its own gate: only a kind whose tool is proven missing AND
    // which the helper cannot answer without it. Text search is the one such
    // kind; a name search still reaches the helper's walk, which vgsMenu
    // accepts.
    function serviceRefuses(kind, state) {
        return state === "missing" && !helperHasFallback(kind);
    }

    // One entry point per decision, each over the same named snapshot. The
    // fields are named rather than positional on purpose: two adjacent booleans
    // transposed at a call site reads correctly and reinstates the original
    // defect, while `fd: ripgrepAvailable` is visible on sight.
    function canDispatchFor(kind, query, probe) {
        return dispatchAllowed(backendStateFor(kind, query, probe), kind);
    }

    // Whether the last answer can be left alone. Only a successful probe that
    // found every tool settles anything: a user told to install fd must see that
    // answer change once they have, and "ready" with fd absent is precisely the
    // state that instruction is given from.
    function probeSettled(probe) {
        const answer = probe || {};
        return answer.state === "ready" && !!answer.fd && !!answer.ripgrep;
    }

    // What a failed probe publishes. A previous SUCCESSFUL answer survives it:
    // re-probing runs on every open of an incomplete machine, and letting one
    // slow re-probe demote "ready" would refuse name search and blame tools that
    // were found seconds earlier. The retry still runs; only the answer on
    // screen is protected.
    function probeFailureOutcome(currentState, attempts, maxAttempts) {
        const mayRetry = attempts < maxAttempts;
        if (currentState === "ready")
            return { state: "ready", retry: mayRetry, publishReason: false };
        if (mayRetry)
            return { state: "retrying", retry: true, publishReason: true };
        return { state: "failed", retry: false, publishReason: true };
    }
    // END SEARCH BACKEND DECISION

    function _probeSnapshot() {
        return { state: statusState, fd: fdAvailable, ripgrep: ripgrepAvailable };
    }

    function backendState(kind, query) {
        return backendStateFor(kind, query, _probeSnapshot());
    }

    function canDispatch(kind, query) {
        return canDispatchFor(kind, query, _probeSnapshot());
    }

    function refreshFolderOpeners() {
        Proc.runCommand("launcher-folder-openers", [
            Paths.vshellCli, "launcher-search", "openers"
        ], (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            try {
                const response = JSON.parse(stdout);
                if (response.ok && Array.isArray(response.openers))
                    root.folderOpeners = response.openers;
            } catch (e) {
                root.errorOccurred(I18n.tr("Unable to detect folder openers"));
            }
        }, 0, 3000);
    }

    // Joined "--flag=value", not two argv entries: a configured root or ignore
    // path beginning with "-" is read as an option name in the separated form
    // and argparse rejects the call.
    function _appendListArgs(args, flag, values) {
        const list = Array.isArray(values) ? values : [];
        for (let i = 0; i < list.length; i++) {
            const value = String(list[i] || "").trim();
            if (value)
                args.push(flag + "=" + value);
        }
    }

    function search(query, params, callback) {
        const kind = params?.kind || kindForType(params?.type);
        const versions = Object.assign({}, _requestVersions);
        const version = (versions[kind] || 0) + 1;
        versions[kind] = version;
        _requestVersions = versions;

        if ((!query || !query.trim()) && kind !== "zoxide") {
            callback?.({ result: { ok: true, kind: kind, hits: [] } });
            return;
        }
        // "text" is the only kind that reaches this: it is the one without a
        // helper fallback, and ripgrep is its tool. A state short of "missing"
        // still dispatches, and the helper answers with the real cause.
        if (serviceRefuses(kind, backendState(kind, query))) {
            callback?.({ error: I18n.tr("ripgrep is required for text search") });
            return;
        }

        const args = [
            Paths.vshellCli, "launcher-search", "search",
            "--kind", kind,
            "--limit", String(params?.limit || 80)
        ];
        _appendListArgs(args, "--root", params?.roots || SettingsData.launcherSearchRoots);
        _appendListArgs(args, "--ignore", params?.ignores || SettingsData.launcherSearchIgnored);
        if (params?.ignoreMounts ?? SettingsData.launcherSearchIgnoreMounts)
            args.push("--ignore-mounts");
        // The query is the user's text and can start with "-", which argparse
        // would read as an option and refuse. It goes last, behind "--".
        args.push("--", query.trim());

        Proc.runCommand("launcher-search-" + kind, args, (stdout, exitCode, stderr) => {
            if ((_requestVersions[kind] || 0) !== version)
                return;
            if (exitCode !== 0) {
                const message = stderr.trim() || I18n.tr("Search failed");
                root.errorOccurred(message);
                callback?.({ error: message });
                return;
            }
            try {
                const response = JSON.parse(stdout);
                if (!response.ok) {
                    callback?.({ error: response.error || I18n.tr("Search failed") });
                    return;
                }
                root.searchResultsReceived(response);
                callback?.({ result: response });
            } catch (e) {
                const message = I18n.tr("Unable to read search results");
                root.errorOccurred(message);
                callback?.({ error: message });
            }
        }, 0, 12000);
    }

    function preview(path, line, query, callback) {
        if (typeof query === "function") {
            callback = query;
            query = "";
        }
        const version = ++_previewVersion;
        if (!path) {
            callback?.({ ok: false, error: "" });
            return;
        }
        const args = [Paths.vshellCli, "launcher-search", "preview", "--lines", "700"];
        if (line)
            args.push("--line", String(line));
        // Joined, because the highlight query is the user's search text and a
        // text search for "-n" now returns hits to preview.
        if (query)
            args.push("--query=" + String(query));
        // Same shape as search(): a path can begin with "-" too.
        args.push("--", String(path));
        Proc.runCommand("launcher-file-preview", args, (stdout, exitCode, stderr) => {
            if (version !== _previewVersion)
                return;
            if (exitCode !== 0) {
                callback?.({ ok: false, error: stderr.trim() || I18n.tr("Preview unavailable") });
                return;
            }
            try {
                callback?.(JSON.parse(stdout));
            } catch (e) {
                callback?.({ ok: false, error: I18n.tr("Preview unavailable") });
            }
        }, 25, 5000);
    }
}
