pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

// Expose the helper catalog for installed and downloadable themes. The helper owns downloads and checksum verification.
Singleton {
    id: root
    readonly property var log: Log.scoped("VGSThemeCatalogService")

    // [{name, mode, pair, source, colors, background, foreground, imagerySize, imageryInstalled,
    //   imageryUpdateAvailable, builtin, downloaded, downloadedRef, preview}]
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
    readonly property int installedCount: (entries || []).filter(e => e.imageryInstalled).length
    readonly property int downloadableCount: (entries || []).filter(e => !e.imageryInstalled).length
    readonly property real downloadableSize: (entries || []).reduce((sum, e) => e.imageryInstalled ? sum : sum + (e.imagerySize || 0), 0)

    signal catalogLoaded

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

    // Every catalog operation reports its outcome here, once, whichever surface started it.
    function _complete(success, message) {
        if (success)
            ToastService.showInfo(message);
        else
            ToastService.showError(I18n.tr("Theme download"), message);
    }

    // BEGIN IMAGERY CARD DECISION
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-source.js extracts and executes it.

    // The one card a wallpaper surface offers for a theme's imagery, from its catalog entry, or null for a theme the
    // catalog does not carry or whose imagery is current. `kind` is "download" while the imagery is not on disk and
    // "update" when the catalog pins a different archive than the one downloaded; `running` is true while a command
    // for the theme runs.
    function imageryCard(entry, pending) {
        if (!entry)
            return null;
        if (!entry.imageryInstalled)
            return {kind: "download", running: !!pending};
        if (entry.imageryUpdateAvailable || pending)
            return {kind: "update", running: !!pending};
        return null;
    }

    // What a Theme view lists for a card. Imagery not on disk leaves its download card as the only entry, on the
    // switcher and in Dash; an update card follows the wallpapers, so an open seeds onto a wallpaper and a
    // reflexive Enter never starts an update. Dash draws the card as a button and drops its entry.
    function themeRail(wallpapers, card) {
        if (!card)
            return wallpapers || [];
        const entry = {card: card, key: "imagery:" + card.kind};
        return card.kind === "download" ? [entry] : (wallpapers || []).concat([entry]);
    }

    // The `theme catalog` verb a card runs: "install" for a download, "update" for an update, "" while one runs.
    function cardOperation(card) {
        if (!card || card.running)
            return "";
        return card.kind === "download" ? "install" : "update";
    }

    // The message a failed command's output carries: its first failed result's error, or "" when there is none to read.
    function failureDetail(output) {
        let data = null;
        try {
            data = JSON.parse(output || "");
        } catch (error) {
            return "";
        }
        const failed = ((data && data.results) || []).find(result => result && result.status === "failed");
        return failed && failed.error ? String(failed.error) : "";
    }
    // END IMAGERY CARD DECISION

    // What an empty Theme view says while this catalog cannot yet tell whether the theme has imagery to download.
    readonly property string stateNotice: (loading && !available) ? I18n.tr("Reading the theme catalog…") : failureText

    function imageryCardFor(name) {
        return root.imageryCard(root.entryFor(name), root.isPending(name));
    }

    function imageryCardLabel(name, card) {
        if (!card)
            return "";
        const size = root.formatSize((root.entryFor(name) || {}).imagerySize);
        if (card.kind === "download")
            return card.running ? I18n.tr("Downloading wallpapers for %1").arg(name) : I18n.tr("Download wallpapers for %1 (%2)").arg(name).arg(size);
        return card.running ? I18n.tr("Updating wallpapers for %1").arg(name) : I18n.tr("Update wallpapers for %1 (%2)").arg(name).arg(size);
    }

    // Start a wallpaper surface's card with a start toast; _complete reports the finish or failure.
    function fetchImagery(name, card) {
        const verb = root.cardOperation(card);
        if (!verb || root.isPending(name))
            return;
        root._runImagery(verb, name);
        ToastService.showInfo(root.imageryCardLabel(name, {kind: card.kind, running: true}));
    }

    // Run downloads as background tasks so they do not block Settings actions.
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
            _complete(false, root.failureDetail(output) || stderr || lastError || fallbackMessage);
            return null;
        }
        try {
            return JSON.parse(output || "{}");
        } catch (e) {
            _complete(false, "Failed to parse download result: " + e);
            return null;
        }
    }

    // Install and update share one run: the pending mark, the command, the catalog refresh, the thumbnail sweep and the report.
    function _runImagery(verb, name) {
        if (!name || isPending(name))
            return;
        _setPending(name, true);
        const failed = verb === "install" ? I18n.tr("Download failed: %1").arg(name) : I18n.tr("Update failed: %1").arg(name);
        _run("vgs-theme-catalog-" + verb + "-" + name, ["theme", "catalog", verb, name, "--json"], 900000,
             function (output, exitCode, stderr) {
                 _setPending(name, false);
                 const data = _finishDownload(output, exitCode, stderr, failed);
                 if (!data)
                     return;
                 const result = (data.results || [])[0] || {};
                 const placed = result.status === (verb === "install" ? "installed" : "updated");
                 // New wallpapers are missing but invisible from the service,
                 // which only sees the CURRENT theme — without a sweep the
                 // theme's rail falls back to full-size sources until it is
                 // applied, which is the prewarm `--all` promises. The request
                 // is only READ by a wallpaper read, so it needs one to act on it.
                 if (placed && typeof VGSThemeService !== "undefined") {
                     VGSThemeService.requestThumbnailSweep();
                     VGSThemeService.refreshWallpapers();
                 }
                 if (placed || result.status === "current")
                     _complete(true, verb === "install" ? I18n.tr("Downloaded %1").arg(name) : I18n.tr("Updated wallpapers for %1").arg(name));
                 else
                     _complete(false, result.error || result.reason || failed);
             });
    }

    function install(name) {
        root._runImagery("install", name);
    }

    function installAll() {
        if (downloadingAll)
            return;
        downloadingAll = true;
        _run("vgs-theme-catalog-install-all", ["theme", "catalog", "install", "--all", "--json"], 7200000,
             function (output, exitCode, stderr) {
                 downloadingAll = false;
                 const data = _finishDownload(output, exitCode, stderr, "Downloading all themes failed");
                 // Request a thumbnail sweep even after a partial download run; successfully installed themes still need cache entries.
                 if (typeof VGSThemeService !== "undefined") {
                     VGSThemeService.requestThumbnailSweep();
                     VGSThemeService.refreshWallpapers();
                 }
                 if (!data)
                     return;
                 const count = (data.installed || []).length;
                 const failed = (data.results || []).filter(r => r.status === "failed");
                 if (failed.length > 0) {
                     _complete(false, I18n.tr("Downloaded %1 themes, %2 failed").arg(count).arg(failed.length));
                     return;
                 }
                 _complete(true, I18n.tr("Downloaded %1 themes").arg(count));
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
                     // The helper prunes the removed theme's thumbnails itself,
                     // so this only refreshes shell state.
                     if (typeof VGSThemeService !== "undefined")
                         VGSThemeService.refreshWallpapers();
                     _complete(true, I18n.tr("Removed %1").arg(name));
                 }
                 else
                     _complete(false, result.error || I18n.tr("Remove failed: %1").arg(name));
             });
    }
}
