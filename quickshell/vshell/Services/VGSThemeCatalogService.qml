pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

// Expose the helper catalog to the wallpaper surfaces and the apply-time download offer. The helper owns downloads and checksum verification.
Singleton {
    id: root
    readonly property var log: Log.scoped("VGSThemeCatalogService")

    // [{name, mode, pair, source, colors, background, foreground, imagerySize, imageryInstalled,
    //   imageryUpdateAvailable, builtin, downloaded, downloadedRef, preview}]
    property var entries: []
    property bool loading: false
    property string lastError: ""
    // Why the catalog is empty, when it is empty for a reason the user can act
    // on. Empty string means "loaded fine".
    property string failureText: ""
    // name -> true while a per-theme download or update is in flight.
    property var pendingNames: ({})
    // The theme an apply asked to offer, settled by the next catalog read.
    property string _offerName: ""

    readonly property bool available: (entries || []).length > 0

    signal catalogLoaded
    // A download offer for an applied theme, with the archive size in bytes.
    signal downloadOffered(string name, real size)

    onCatalogLoaded: root._settleOffer()

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

    // BEGIN DOWNLOAD OFFER DECISION
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-selection.js extracts and executes it.

    // Whether an applied theme's catalog entry earns a download offer. The entry
    // comes from a catalog read made after the apply, so a download that just
    // finished reads as installed. Offline behaves as Not now. `applied` says the
    // theme is still the applied one when the read returns: the user may have
    // applied another meanwhile, and the offer must not name the previous theme.
    function downloadOffer(entry, online, pending, applied) {
        if (!entry || entry.imageryInstalled !== false || applied !== true)
            return false;
        return entry.imagerySize > 0 && !pending && online === true;
    }
    // END DOWNLOAD OFFER DECISION

    // No reported network backend says nothing about connectivity, so only a
    // backend that reports a disconnect counts as offline.
    readonly property bool online: !NetworkService.networkAvailable || NetworkService.networkStatus !== "disconnected"

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
                // binary, timeout): say so instead of leaving an empty view
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

    // Called once a theme the user picked has applied. `installed` is the theme
    // list's answer, read before the apply: a theme it reports installed costs no
    // catalog read. The read is the shared refresh, so the wallpaper surfaces see
    // the same entries the offer decides on.
    function offerDownload(name, installed) {
        if (!name || installed !== false)
            return;
        _offerName = name;
        refresh();
    }

    // Settle a pending offer once a catalog read lands. A failed read leaves no entry, so it offers nothing.
    function _settleOffer() {
        const name = _offerName;
        _offerName = "";
        if (!name)
            return;
        const entry = entryFor(name);
        // currentTheme refreshes asynchronously; the applied name is set as the apply lands.
        if (downloadOffer(entry, online, isPending(name), SettingsData.currentThemeName === name))
            downloadOffered(name, entry.imagerySize);
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
                     // A theme applied before its download had no wallpaper, so the
                     // theme still applied takes its downloaded one now. The applied
                     // name is set as an apply lands, unlike currentTheme.
                     if (verb === "install" && SettingsData.currentThemeName === name)
                         VGSThemeService.applyBlueprint(name);
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
}
