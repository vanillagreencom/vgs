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
    // "pending" until the probe answers, then "ready", or "failed" once the
    // retries are spent. The tool flags mean nothing outside "ready", so no
    // caller may report a tool as missing on their strength alone.
    property string statusState: "pending"
    property string statusError: ""
    property int _statusAttempts: 0
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

    function rediscover() {
        _statusAttempts = 0;
        _probeStatus();
    }

    // Re-probe only where a previous probe gave up. A surface that opens after
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
        Proc.runCommand("launcher-search-status", [Paths.vshellCli, "launcher-search", "status"], (stdout, exitCode, stderr) => {
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
            // Bounded backoff. One failed probe used to leave search
            // unanswerable for the life of the shell; retrying forever would
            // spawn a process a second for the same lifetime.
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
    // before fd is consulted, so path completion must not be gated on fd.
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

    // Only a proven-missing tool blocks a search. "unknown" dispatches: the
    // search itself then fails loudly with a real cause, which beats a silent
    // refusal built on an answer nobody has.
    function dispatchAllowed(state) {
        return state === "available" || state === "unknown";
    }

    // Whether this service refuses the call outright. Text search shells out to
    // ripgrep and fails with no fallback, while name search falls back to the
    // helper's own directory walk — which vgsMenu accepts and the overview
    // declines at its own gate.
    function helperHasFallback(kind) {
        return kind === "files" || kind === "folders" || kind === "all";
    }
    // END SEARCH BACKEND DECISION

    function backendState(kind, query) {
        return backendStateFor(kind, query, {
            state: statusState,
            fd: fdAvailable,
            ripgrep: ripgrepAvailable
        });
    }

    function canDispatch(kind, query) {
        return dispatchAllowed(backendState(kind, query));
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
        if (backendState(kind, query) === "missing" && !helperHasFallback(kind)) {
            callback?.({ error: I18n.tr("ripgrep is required for text search") });
            return;
        }

        const args = [
            Paths.vshellCli, "launcher-search", "search", query.trim(),
            "--kind", kind,
            "--limit", String(params?.limit || 80)
        ];
        _appendListArgs(args, "--root", params?.roots || SettingsData.launcherSearchRoots);
        _appendListArgs(args, "--ignore", params?.ignores || SettingsData.launcherSearchIgnored);
        if (params?.ignoreMounts ?? SettingsData.launcherSearchIgnoreMounts)
            args.push("--ignore-mounts");

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
        const args = [Paths.vshellCli, "launcher-search", "preview", path, "--lines", "700"];
        if (line)
            args.push("--line", String(line));
        if (query)
            args.push("--query", String(query));
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
