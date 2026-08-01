pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

// Live launcher search. The historical name is retained so existing imports do
// not churn, but search is VGS-owned and backed by fd + ripgrep rather than the
// stale external dsearch index.
Singleton {
    id: root

    property bool dsearchAvailable: true
    property bool supportsTypeFilter: true
    property bool versionChecked: true
    property int indexVersion: 3
    property string backendName: "fd + ripgrep"
    property bool fdAvailable: false
    property bool ripgrepAvailable: false
    property var folderOpeners: [{ id: "default", label: I18n.tr("Preferred app"), icon: "open_in_new" }]
    property var _requestVersions: ({})
    property int _previewVersion: 0

    signal searchResultsReceived(var results)
    signal statsReceived(var stats)
    signal errorOccurred(string error)

    Component.onCompleted: {
        rediscover();
        refreshFolderOpeners();
    }

    function rediscover() {
        Proc.runCommand("launcher-search-status", [Paths.vshellCli, "launcher-search", "status"], (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            try {
                const status = JSON.parse(stdout);
                root.fdAvailable = !!status.fd;
                root.ripgrepAvailable = !!status.ripgrep;
                root.backendName = status.backend || "fd + ripgrep";
                root.dsearchAvailable = root.fdAvailable;
                root.statsReceived(status);
            } catch (e) {
                root.errorOccurred(I18n.tr("Unable to read launcher search status"));
            }
        }, 0, 3000);
    }

    function ping(callback) {
        if (callback)
            callback({ result: { ok: dsearchAvailable, backend: backendName } });
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
        const kind = params?.kind || (params?.type === "dir" ? "folders" : params?.type === "text" ? "text" : "files");
        const versions = Object.assign({}, _requestVersions);
        const version = (versions[kind] || 0) + 1;
        versions[kind] = version;
        _requestVersions = versions;

        if ((!query || !query.trim()) && kind !== "zoxide") {
            callback?.({ result: { ok: true, kind: kind, hits: [] } });
            return;
        }
        if (kind === "text" && !ripgrepAvailable) {
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
