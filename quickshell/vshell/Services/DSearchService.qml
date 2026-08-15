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
    // report a tool as missing on their strength alone — and everything past
    // the first failure is honestly "nobody knows" rather than "checking",
    // which is what lets dispatch resume instead of waiting out the retries.
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

    // Re-probe only where a previous episode gave up. A surface that opens after
    // the shell has been running for hours is the moment a transient failure
    // gets a second chance; re-probing a settled answer would spawn a process
    // per open for nothing.
    function ensureStatus() {
        if (statusState === "failed")
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
        root.statusError = reason;
        if (root._statusAttempts < root._statusMaxAttempts) {
            // Bounded backoff, one budget per episode. One failed probe used to
            // leave search unanswerable for the life of the shell; retrying
            // forever would spawn a process a second for the same lifetime.
            //
            // The state leaves "pending" on the FIRST failure rather than at the
            // end of the sequence: the answer is already unknown, and holding
            // "checking" across the retries refused every search for the ~12s
            // they take on a machine whose tools are fine.
            root.statusState = "retrying";
            statusRetryTimer.interval = 1000 * root._statusAttempts;
            statusRetryTimer.start();
            return;
        }
        root.statusState = "failed";
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
    // condition mirrors that branch, "~" and "/" alike; from the overview only
    // the "~" form arrives, because a leading "/" is the launcher's own
    // file-search trigger and parseFileSearchPrefix consumes it.
    function pathCompletion(kind, query) {
        return kind === "folders" && /^[~/]/.test(String(query || "").trim());
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
    // dispatch. "available" always may. "unknown" may only where dispatching
    // cannot silently buy that walk: ripgrep fails fast with a real cause, and
    // a path completion is one iterdir. A name search in the unknown state is
    // refused instead — a full walk of the roots per keystroke is the cost the
    // fd gate exists to avoid, and taking it because a probe could not run
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

    // The composition itself, so which property lands in which slot is
    // executable rather than assumed. Reading the probe out of the singleton is
    // then the only thing left outside the region, and it is one line long.
    function backendStateFrom(kind, query, probeState, fdPresent, rgPresent) {
        return backendStateFor(kind, query, {
            state: probeState,
            fd: fdPresent,
            ripgrep: rgPresent
        });
    }

    function canDispatchFrom(kind, query, probeState, fdPresent, rgPresent) {
        return dispatchAllowed(backendStateFrom(kind, query, probeState, fdPresent, rgPresent), kind);
    }
    // END SEARCH BACKEND DECISION

    function backendState(kind, query) {
        return backendStateFrom(kind, query, statusState, fdAvailable, ripgrepAvailable);
    }

    function canDispatch(kind, query) {
        return canDispatchFrom(kind, query, statusState, fdAvailable, ripgrepAvailable);
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

    function _appendListArgs(args, flag, values) {
        const list = Array.isArray(values) ? values : [];
        for (let i = 0; i < list.length; i++) {
            const value = String(list[i] || "").trim();
            if (value)
                args.push(flag, value);
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
        if (query)
            args.push("--query", String(query));
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
