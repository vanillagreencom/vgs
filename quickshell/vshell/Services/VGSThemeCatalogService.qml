pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

// The download catalog: every theme VGS publishes, installed or not.
//
// Packages ship one theme by default (the rest are ~1.1 GiB of wallpapers), so
// browsing installed themes alone shows a single entry. The helper owns the
// catalog, the downloads and the checksum verification (`vshell theme catalog`);
// this service is the thin QML front for it.
Singleton {
    id: root
    readonly property var log: Log.scoped("VGSThemeCatalogService")

    // [{name, mode, pair, source, colors, background, foreground, accent, size,
    //   installed, builtin, downloaded, preview}]
    property var entries: []
    property bool loading: false
    property string catalogRef: ""
    property string lastError: ""
    // Why the catalog is empty, when it is empty for a reason the user can act
    // on. Empty string means "loaded fine".
    property string failureText: ""
    // name -> true while a per-theme download/remove is in flight.
    property var pendingNames: ({})
    property bool downloadingAll: false

    readonly property bool busy: downloadingAll || Object.keys(pendingNames).length > 0
    readonly property bool available: (entries || []).length > 0
    readonly property int installedCount: (entries || []).filter(e => e.installed).length
    readonly property int downloadableCount: (entries || []).filter(e => !e.installed).length
    readonly property real downloadableSize: (entries || []).reduce((sum, e) => e.installed ? sum : sum + (e.size || 0), 0)

    signal catalogLoaded
    signal operationCompleted(bool success, string message)

    function isPending(name) {
        return !!(pendingNames && pendingNames[name]);
    }

    function _setPending(name, value) {
        const next = Object.assign({}, pendingNames);
        if (value)
            next[name] = true;
        else
            delete next[name];
        pendingNames = next;
    }

    function formatSize(bytes) {
        const value = bytes || 0;
        if (value >= 1024 * 1024 * 1024)
            return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB";
        if (value >= 1024 * 1024)
            return Math.round(value / (1024 * 1024)) + " MB";
        return Math.max(1, Math.round(value / 1024)) + " KB";
    }

    function entryFor(name) {
        const list = entries || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].name === name)
                return list[i];
        }
        return null;
    }

    // Downloads are long (a single theme is tens of MB, --all is ~1.1 GiB), so
    // every call is a background task: they must never gate the settings UI.
    function _run(id, args, timeoutMs, callback) {
        lastError = "";
        Proc.runCommand(id, [Paths.vshellCli].concat(args), function (output, exitCode, stderr) {
            if (exitCode !== 0) {
                lastError = (stderr && stderr.trim().length > 0) ? stderr : output;
                log.warn("Command failed", args.join(" "), "exit", exitCode, lastError);
            }
            callback(output, exitCode, stderr || "");
        }, 0, timeoutMs);
    }

    function refresh() {
        loading = true;
        _run("vgs-theme-catalog-list", ["theme", "catalog", "list", "--json"], 120000, function (output, exitCode, stderr) {
            loading = false;
            if (exitCode !== 0) {
                // Includes the case where the CLI could not run at all (missing
                // binary, timeout): say so instead of leaving an empty browser
                // that looks like a catalog with nothing in it.
                entries = [];
                failureText = stderr || lastError || (exitCode === 124
                    ? I18n.tr("Timed out reading the theme catalog")
                    : I18n.tr("Could not read the theme catalog"));
                catalogLoaded();
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                entries = data.themes || [];
                catalogRef = data.ref || "";
                failureText = "";
                catalogLoaded();
            } catch (e) {
                lastError = "Failed to parse theme catalog: " + e;
                failureText = lastError;
                entries = [];
                catalogLoaded();
            }
        });
    }

    function _finishDownload(output, exitCode, stderr, fallbackMessage) {
        refresh();
        if (typeof VGSThemeService !== "undefined")
            VGSThemeService.refreshBlueprints();
        if (exitCode !== 0) {
            operationCompleted(false, stderr || lastError || fallbackMessage);
            return null;
        }
        try {
            return JSON.parse(output || "{}");
        } catch (e) {
            operationCompleted(false, "Failed to parse download result: " + e);
            return null;
        }
    }

    function install(name) {
        if (!name || isPending(name))
            return;
        _setPending(name, true);
        _run("vgs-theme-catalog-install-" + name, ["theme", "catalog", "install", name, "--json"], 900000,
             function (output, exitCode, stderr) {
                 _setPending(name, false);
                 const data = _finishDownload(output, exitCode, stderr, "Download failed: " + name);
                 if (!data)
                     return;
                 const result = (data.results || [])[0] || {};
                 if (result.status === "installed")
                     operationCompleted(true, I18n.tr("Downloaded %1").arg(name));
                 else
                     operationCompleted(false, result.error || result.reason || I18n.tr("Download failed: %1").arg(name));
             });
    }

    function installAll() {
        if (downloadingAll)
            return;
        downloadingAll = true;
        _run("vgs-theme-catalog-install-all", ["theme", "catalog", "install", "--all", "--json"], 7200000,
             function (output, exitCode, stderr) {
                 downloadingAll = false;
                 const data = _finishDownload(output, exitCode, stderr, "Downloading all themes failed");
                 if (!data)
                     return;
                 const count = (data.installed || []).length;
                 const failed = (data.results || []).filter(r => r.status === "failed");
                 if (failed.length > 0) {
                     operationCompleted(false, I18n.tr("Downloaded %1 themes, %2 failed").arg(count).arg(failed.length));
                     return;
                 }
                 operationCompleted(true, I18n.tr("Downloaded %1 themes").arg(count));
             });
    }

    function remove(name) {
        if (!name || isPending(name))
            return;
        _setPending(name, true);
        _run("vgs-theme-catalog-remove-" + name, ["theme", "catalog", "remove", name, "--json"], 120000,
             function (output, exitCode, stderr) {
                 _setPending(name, false);
                 const data = _finishDownload(output, exitCode, stderr, "Remove failed: " + name);
                 if (!data)
                     return;
                 const result = (data.results || [])[0] || {};
                 if (result.status === "removed") {
                     // A removed theme takes its wallpapers with it, so its
                     // thumbnails are orphaned; nothing else here would ever
                     // trigger the sweep that prunes them.
                     if (typeof VGSThemeService !== "undefined") {
                         VGSThemeService.requestThumbnailPrune();
                         VGSThemeService.refreshWallpapers();
                     }
                     operationCompleted(true, I18n.tr("Removed %1").arg(name));
                 }
                 else
                     operationCompleted(false, result.error || I18n.tr("Remove failed: %1").arg(name));
             });
    }
}
