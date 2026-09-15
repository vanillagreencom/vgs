pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import "RestyleQueue.js" as RestyleQueue
import "ThemeRequest.js" as ThemeRequest

Singleton {
    id: root
    readonly property var log: Log.scoped("VGSThemeService")

    // Pending helper calls keyed by Proc command id. Proc coalesces rapid
    // same-id calls into one launch with one callback, so a plain counter
    // leaks and pins `busy` true forever; a per-id map stays balanced.
    property var _pending: ({})
    property int inflight: 0
    // Restyles have their own single-flight queue because Proc only coalesces
    // calls that are still in its debounce window; it does not serialize
    // processes after launch. Immutable transitions keep QML bindings notified
    // and busy asserted across queued hand-offs.
    property var _restyleQueueState: RestyleQueue.emptyState()
    readonly property bool busy: inflight > 0
    readonly property bool restyling: RestyleQueue.isBusy(_restyleQueueState)
    property var _pendingApps: ({})
    property string lastMessage: ""
    property string lastError: ""
    property var blueprints: []
    // Keep error state separate for each read so concurrent operations cannot overwrite its explanation.
    // Consumers must check the corresponding flag before treating an empty list as a valid result.
    property bool blueprintsLoadFailed: false
    property string blueprintsLoadError: ""
    property bool wallpapersLoadFailed: false
    property string wallpapersLoadError: ""
    // The theme whose wallpaper set `themeWallpapers` currently holds. A failed
    // read LEAVES the previous list, and `applyBlueprint` re-reads on success,
    // so after a theme switch whose re-read failed the list on screen belongs to
    // the theme BEFORE it — which no surface could say without this.
    property string themeWallpapersTheme: ""
    property var currentTheme: ({})
    property string selectedWallpaper: ""

    // The ONE wording every surface shows over a retained wallpaper list, so the
    // dash tab and the switcher banner cannot describe the same state
    // differently. Empty while the list is current. "Showing X's set" is the
    // load-bearing half: after a theme switch the retained list is a DIFFERENT
    // theme's, and Enter would apply a wallpaper from outside the active theme.
    readonly property string wallpapersStaleNotice: {
        if (!wallpapersLoadFailed)
            return "";
        const loaded = themeWallpapersTheme;
        const active = (currentTheme || {}).name || "";
        if (loaded && active && loaded !== active)
            return I18n.tr("Could not read this theme's wallpapers — showing %1's set").arg(loaded);
        return I18n.tr("Could not read this theme's wallpapers — showing the last set that loaded");
    }
    readonly property var paletteArgMap: ({
        background: "background",
        foreground: "foreground",
        accent: "accent",
        cursor: "cursor",
        selectionBackground: "selection_background",
        selectionForeground: "selection_foreground",
        black: "black",
        red: "red",
        green: "green",
        yellow: "yellow",
        blue: "blue",
        magenta: "magenta",
        cyan: "cyan",
        white: "white",
        brightBlack: "bright_black",
        brightRed: "bright_red",
        brightGreen: "bright_green",
        brightYellow: "bright_yellow",
        brightBlue: "bright_blue",
        brightMagenta: "bright_magenta",
        brightCyan: "bright_cyan",
        brightWhite: "bright_white"
    })

    property var themeApps: []
    // Composed wallpaper set of the current theme: [{file, path, origin, default}]
    property var themeWallpapers: []
    // What the All view browses: the wallpaper folder's images, then every installed theme's set, each
    // entry's `source` naming "folder" or its theme. A failed read keeps the previous list, as themeWallpapers does.
    property var allWallpapers: []
    property bool allWallpapersLoadFailed: false
    property string allWallpapersLoadError: ""
    property int _allWallpapersReadSeq: 0
    readonly property string wallpaperFolderPath: {
        const configured = (SettingsData.wallpaperFolder || "").trim();
        if (configured)
            return configured.startsWith("~") ? Paths.strip(Paths.home) + configured.substring(1) : configured;
        return Paths.strip(Paths.home) + "/Pictures/Wallpapers";
    }
    // Per-app template roles keyed by app id: [{role, value, overridden}]
    property var appRoles: ({})

    signal blueprintsLoaded
    signal currentLoaded
    signal themeAppsLoaded
    signal wallpapersLoaded
    signal appRolesLoaded(string app)
    signal applyCompleted(bool success, string message)
    // Completion with the originating request id lets switchers identify their own apply result.
    // applyCompleted also reports unrelated operations.
    signal applyFinished(string requestId, bool success, string message)

    // Apply requests begun and not yet answered, keyed by a request id that is
    // unique per CALL. Holds the request whose helper process is running and
    // every request waiting in `_applyQueue`, which is what keeps a surface
    // gated on `applyInFlight` — the Clear Wallpaper button among them — shut
    // while a queued apply still has to run.
    // Deliberately narrower than `busy`: `busy` counts every non-background
    // command, so gating a switcher's Enter on it blocks while an unrelated
    // `theme restyle` or per-app override from a settings tab runs, and unblocks
    // while the switcher's own background reads are still in flight.
    property var _applyInFlight: ({})
    readonly property bool applyInFlight: Object.keys(_applyInFlight).length > 0
    // Use a unique id per call so overlapping applies retain separate completion records.
    property int _applyRequestSeq: 0
    // The apply request that last claimed `selectedWallpaper`, or "" when none
    // does. Keyed on the REQUEST, never the path — see `_ownsWallpaperSlot`.
    // It governs that optimistic UI value alone. The session write is not gated
    // on it: every apply that succeeds commits its own wallpaper.
    property string _wallpaperSlotOwner: ""

    // The apply whose helper process is running, or "" when none is. Only one
    // APPLY runs at a time: two helper processes race each other for the helper's
    // own mutation flock, so whichever wins it second is the last to write both
    // the helper's state and, through its own callback, `session.json`. Two picks
    // in quick succession would then settle on whichever the kernel let finish
    // last rather than the one the user chose last. Dispatch order is the only
    // thing that fixes execution order. The slot reaches `_runApply` alone; every
    // other mutating subcommand this service launches still races an apply for
    // that flock, and so does one MethodTheme launches, which D019 records.
    property string _applyDispatched: ""
    // Applies waiting for that slot, oldest first. First in, first out rather
    // than superseding the waiting one: `applyFinished` carries success or
    // failure and nothing else, and ThemeApplyReporter turns every non-success
    // into an error toast, so a superseded apply has no honest outcome to send.
    property var _applyQueue: []

    // `label` only makes the returned request id readable; it is NOT a Proc id
    // — see `_dispatchApply`. Every apply answers its own callback, so a token leaves
    // `_applyInFlight` when its own `_finishApply` runs.
    function _beginApply(label) {
        _applyRequestSeq += 1;
        const requestId = label + "#" + _applyRequestSeq;
        const next = Object.assign({}, _applyInFlight);
        next[requestId] = true;
        _applyInFlight = next;
        return requestId;
    }

    // Ends the request and announces it on both signals: `applyCompleted` for
    // the settings tabs that report any outcome, `applyFinished` for a caller
    // that is waiting on this request specifically.
    function _finishApply(requestId, success, message) {
        if (_applyInFlight[requestId]) {
            const next = Object.assign({}, _applyInFlight);
            delete next[requestId];
            _applyInFlight = next;
        }
        if (_wallpaperSlotOwner === requestId)
            _wallpaperSlotOwner = "";
        // Free the slot and start the next apply BEFORE the signals: a handler
        // that throws returns into this frame, and past the emission it would
        // strand the queue behind a slot nothing frees, leaving every later
        // apply waiting forever.
        if (_applyDispatched === requestId) {
            _applyDispatched = "";
            if (_applyQueue.length > 0) {
                const waiting = _applyQueue[0];
                _applyQueue = _applyQueue.slice(1);
                _dispatchApply(waiting.requestId, waiting.args, waiting.callback);
            }
        }
        applyCompleted(success, message);
        applyFinished(requestId, success, message);
    }

    function _persistAppliedTheme(name) {
        if (!name || typeof SettingsData === "undefined")
            return;
        SettingsData.set("currentThemeCategory", "vgs");
        SettingsData.set("currentThemeName", name);
    }

    function _markGreeterThemeSyncPending() {
        if (typeof SettingsData === "undefined" || SettingsData.isGreeterMode)
            return;
        SettingsData.set("greeterSyncPending", true);
    }

    // backgroundTask: long-running helper calls (theme init, the thumbnail sweep) must not
    // count toward `busy`, or every Apply button goes dead for minutes.
    // `id` is this call's bookkeeping key in `_pending`; `procId` is the id Proc
    // COALESCES on and defaults to it — `_dispatchApply` is the one caller that
    // wants them different. Every other caller runs its subcommand here with no
    // apply slot, so it takes the helper's mutation flock alongside an apply
    // rather than behind it.
    function _run(id, args, callback, timeoutMs, backgroundTask, procId) {
        // Theme helpers read settings.json and session.json, and some write settings.json back.
        SettingsData.flushSettings();
        SessionData.flushSettings();
        const coalesceId = (procId === undefined) ? id : procId;
        if (!backgroundTask) {
            _pending[id] = true;
            inflight = Object.keys(_pending).length;
        }
        lastError = "";
        Proc.runCommand(coalesceId, [Paths.vshellCli].concat(args), function(output, exitCode, stderr) {
            if (!backgroundTask) {
                delete _pending[id];
                inflight = Object.keys(_pending).length;
            }
            const combinedError = (stderr && stderr.trim().length > 0) ? stderr : output;
            if (exitCode !== 0) {
                lastError = combinedError || ("Command failed: " + args.join(" "));
                log.warn("Command failed", args.join(" "), "exit", exitCode, lastError);
            }
            if (callback)
                callback(output, exitCode, stderr || "");
        }, 0, timeoutMs || 120000);
    }

    // Take the apply slot, or wait for it. Two applies from separate key presses
    // both launch and both answer, one after the other — see `_applyDispatched`
    // for why they must not overlap.
    function _runApply(requestId, args, callback) {
        if (_applyDispatched !== "") {
            _applyQueue = _applyQueue.concat([{requestId: requestId, args: args, callback: callback}]);
            return;
        }
        _dispatchApply(requestId, args, callback);
    }

    // Hand one apply to the helper and hold the slot until its callback answers.
    // The one place a launch can fail, and it always answers the request it took:
    // the slot is already this request's when `_run` runs, so finishing it here
    // frees the slot, clears its `_applyInFlight` token and starts the next
    // waiter. A request that holds the slot with nothing to answer it is
    // therefore unrepresentable, and a run of failing launches empties the queue
    // instead of parking it. Every apply reaches the helper through here, the
    // free-slot path included, so there is one recovery and not one per caller.
    // An EMPTY Proc id makes Proc mint its own, so no apply is ever coalesced with
    // another and every apply runs its own process into one `_finishApply`.
    function _dispatchApply(requestId, args, callback) {
        _applyDispatched = requestId;
        try {
            _run(requestId, args, callback, undefined, false, "");
        } catch (e) {
            _finishApply(requestId, false, "Could not start the theme helper: " + e);
        }
    }

    function refresh() {
        refreshCurrent();
        refreshBlueprints();
        refreshApps();
    }

    function refreshApps() {
        _run("vgs-theme-apps", ["theme", "apps", "--json"], function(output, exitCode) {
            if (exitCode !== 0)
                return;
            try {
                const data = JSON.parse(output || "{}");
                themeApps = data.apps || [];
                themeAppsLoaded();
            } catch (e) {
                lastError = "Failed to parse theme apps: " + e;
            }
        }, 120000, true);
    }

    function appBusy(app) {
        return !!(_pendingApps && _pendingApps[app]);
    }

    function _setAppBusy(app, value) {
        _pendingApps = ThemeRequest.setAppBusy(_pendingApps, app, value);
    }

    function _messageWithApplyWarnings(message, output) {
        try {
            const data = JSON.parse(output || "{}");
            const warnings = (data.warnings || []).slice();
            const applied = data.applied || data.apply || {};
            for (const warning of (applied.warnings || []))
                warnings.push(warning);
            return warnings.length > 0 ? message + " · warnings: " + warnings.join("; ") : message;
        } catch (e) {
            return message;
        }
    }

    function setAppEnabled(app, enabled) {
        if (!app)
            return;
        // The helper owns the settings.json write (re-rendering the target on
        // enable); SettingsData picks the external edit up via its file watcher.
        _setAppBusy(app, true);
        _run("vgs-theme-app-toggle-" + app, ThemeRequest.appToggleArgs(app, enabled), function(output, exitCode, stderr) {
            _setAppBusy(app, false);
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Toggle failed: " + app));
                return;
            }
            refreshApps();
            const message = app + (enabled ? " theming enabled" : " theming disabled (last output left in place)");
            applyCompleted(true, _messageWithApplyWarnings(message, output));
        }, 120000, true);
    }

    function editAppFile(app, themeName) {
        const args = ["theme", "edit-app", app, "--json"];
        if (themeName)
            args.push("--theme", themeName);
        _run("vgs-theme-edit-app", args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Edit failed: " + app));
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                if (data.path) {
                    Quickshell.execDetached(["xdg-open", data.path]);
                    applyCompleted(true, (data.created ? "Created " : "Opening ") + data.path);
                }
                refresh();
            } catch (e) {
                applyCompleted(false, "Failed to parse edit-app result: " + e);
            }
        });
    }

    function resetAppFile(app, themeName) {
        const args = ["theme", "reset-app", app, "--json"];
        if (themeName)
            args.push("--theme", themeName);
        _run("vgs-theme-reset-app", args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Reset failed: " + app));
                return;
            }
            refresh();
            applyCompleted(true, app + " reset to generated");
        });
    }

    function setPair(name, pair) {
        if (!name)
            return;
        _run("vgs-theme-set-pair", ["theme", "set-pair", name, pair || "", "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || "Pairing failed");
                return;
            }
            refreshBlueprints();
            applyCompleted(true, pair ? (name + " now pairs with " + pair) : (name + " pairing cleared"));
        });
    }

    // The helper stores the star in the theme's overlay. The listed entry flips
    // before the helper runs, because the list re-read that confirms it takes
    // seconds, and flips back when the helper refuses.
    function setStarred(name, starred) {
        if (!name)
            return;
        const listed = (blueprints || []).find(bp => bp.name === name);
        const previous = !!listed && listed.starred === true;
        _setListedStar(name, starred);
        _run("vgs-theme-star", ["theme", starred ? "star" : "unstar", name, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                _setListedStar(name, previous);
                ToastService.showError(I18n.tr("VGS theme error"), stderr || output || "Starring failed");
                return;
            }
            refreshBlueprints();
        });
    }

    function _setListedStar(name, starred) {
        blueprints = (blueprints || []).map(bp => bp.name === name ? Object.assign({}, bp, { starred: starred }) : bp);
    }

    function deleteTheme(name) {
        if (!name)
            return;
        _run("vgs-theme-delete", ["theme", "delete", name, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Delete failed: " + name));
                return;
            }
            // A deleted theme takes its wallpapers with it, so its thumbnails
            // are orphaned exactly as a removed wallpaper's are.
            root.requestThumbnailSweep();
            refreshWallpapers();
            refreshBlueprints();
            applyCompleted(true, "Deleted " + name);
        });
    }

    function duplicateTheme(name, newName) {
        if (!name)
            return;
        const args = ["theme", "duplicate", name, "--json"];
        if (newName)
            args.push("--as", newName);
        _run("vgs-theme-duplicate", args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Duplicate failed: " + name));
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                refreshBlueprints();
                applyCompleted(true, name + " duplicated to editable user theme " + (data.name || ""));
            } catch (e) {
                applyCompleted(false, "Failed to parse duplicate result: " + e);
            }
        });
    }

    function refreshCurrent() {
        _run("vgs-theme-current", ["theme", "current", "--json"], function(output, exitCode) {
            if (exitCode !== 0)
                return;
            try {
                currentTheme = JSON.parse(output || "{}");
                selectedWallpaper = currentTheme.wallpaper || selectedWallpaper;
                currentLoaded();
            } catch (e) {
                lastError = "Failed to parse current theme: " + e;
            }
        }, 120000, true);
    }

    function refreshBlueprints() {
        _run("vgs-theme-list", ["theme", "list", "--json"], function(output, exitCode) {
            if (exitCode !== 0) {
                blueprintsLoadFailed = true;
                blueprintsLoadError = lastError;
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                blueprints = data.blueprints || [];
                blueprintsLoadFailed = false;
                blueprintsLoadError = "";
                blueprintsLoaded();
            } catch (e) {
                lastError = "Failed to parse blueprints: " + e;
                blueprintsLoadFailed = true;
                blueprintsLoadError = lastError;
            }
        }, 120000, true);
    }

    // Generation token for the wallpaper read. Proc coalesces only SAME-TICK
    // calls, so two overlapping `theme wallpapers` reads both launch and both
    // call back — and the OLDER one can land last. That is reachable in one
    // ordinary sequence: opening the wallpaper switcher dispatches a read, an
    // apply succeeds and dispatches another, and if the pre-apply read finishes
    // second it presents the PREVIOUS theme's wallpapers as fresh, clearing the
    // stale notice that would otherwise have said so.
    property int _wallpapersReadSeq: 0

    function refreshWallpapers() {
        const readId = ++root._wallpapersReadSeq;
        _run("vgs-theme-wallpapers", ["theme", "wallpapers", "--json"], function(output, exitCode) {
            // A newer read owns the list; this one answers about a theme that
            // may no longer be the current one.
            if (readId !== root._wallpapersReadSeq)
                return;
            if (exitCode !== 0) {
                // The previous list is LEFT in place. Discarding a working list
                // because one refresh failed destroys a usable browse; the flag
                // is what surfaces say the data may be stale with.
                wallpapersLoadFailed = true;
                wallpapersLoadError = lastError;
                wallpapersLoaded();
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                themeWallpapers = data.wallpapers || [];
                themeWallpapersTheme = data.theme || "";
                wallpapersLoadFailed = false;
                wallpapersLoadError = "";
                wallpapersLoaded();
                root._sweepWallpaperThumbs();
            } catch (e) {
                lastError = "Failed to parse theme wallpapers: " + e;
                wallpapersLoadFailed = true;
                wallpapersLoadError = lastError;
            }
        });
    }

    // Like refreshWallpapers: only the latest read commits, and a failed read keeps the previous list.
    function refreshAllWallpapers() {
        const readId = ++root._allWallpapersReadSeq;
        _run("vgs-theme-wallpapers-all", ["theme", "wallpapers", "--all", "--folder", wallpaperFolderPath, "--json"], function(output, exitCode) {
            if (readId !== root._allWallpapersReadSeq)
                return;
            if (exitCode !== 0) {
                allWallpapersLoadFailed = true;
                allWallpapersLoadError = lastError;
                return;
            }
            try {
                allWallpapers = JSON.parse(output || "{}").wallpapers || [];
                allWallpapersLoadFailed = false;
                allWallpapersLoadError = "";
            } catch (e) {
                allWallpapersLoadFailed = true;
                allWallpapersLoadError = "Failed to parse wallpapers: " + e;
            }
        });
    }

    // The wording both wallpaper surfaces show for a source, "theme" or "all": the banner over a list a failed
    // read retained, and the text for an empty list.
    function staleNoticeFor(source) {
        if (source !== "all")
            return wallpapersStaleNotice;
        return allWallpapersLoadFailed ? I18n.tr("Could not list wallpapers — showing the last list that loaded") : "";
    }

    function emptyTextFor(source) {
        if (source === "all") {
            if (allWallpapersLoadFailed)
                return I18n.tr("Could not list wallpapers") + (allWallpapersLoadError ? "\n" + allWallpapersLoadError : "");
            return I18n.tr("No images in %1 or any installed theme").arg(Paths.shortenHome(wallpaperFolderPath));
        }
        if (wallpapersLoadFailed)
            return I18n.tr("Could not read this theme's wallpapers") + (wallpapersLoadError ? "\n" + wallpapersLoadError : "");
        // Until the catalog answers, an empty set can be imagery that is not downloaded yet.
        const catalogNotice = typeof VGSThemeCatalogService !== "undefined" ? VGSThemeCatalogService.stateNotice : "";
        return catalogNotice || I18n.tr("This theme has no wallpapers");
    }

    // BEGIN WALLPAPER MEMBERSHIP DECISION
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-source.js extracts and executes it.

    // Whether an All-view entry already belongs to the applied theme: it is one of that theme's own, or the
    // theme's set holds a file of its name. Membership is by file name, so a folder image stays marked while the
    // set holds any file of that name, and a copy wallpaper-add renamed is marked as the theme's own entry.
    // `entriesTheme` names whose set `themeEntries` is: a failed read retains the previous theme's list, and
    // its file names say nothing about the applied theme. An entry the user removed from the applied theme's set
    // is still listed under that theme and belongs to it no longer.
    function inThemeSet(entry, themeName, themeEntries, entriesTheme) {
        if (!entry || !themeName)
            return false;
        if (entry.source === themeName)
            return entry.removed !== true;
        if (entriesTheme !== themeName)
            return false;
        return (themeEntries || []).some(own => own.file === entry.file);
    }

    // The caption an All-view entry carries: the set it comes from, `folderLabel` for the wallpaper folder, and
    // never its file name, so the All view reads like the Theme view.
    function sourceTag(entry, folderLabel) {
        return entry.source === "folder" ? folderLabel : String(entry.source || "");
    }

    // Whether a surface offers Delete wallpaper for an entry. wallpaper-delete refuses a packaged wallpaper, so it
    // is not offered; a folder image carries no origin and is.
    function offersDelete(entry) {
        return !!entry && entry.origin !== "builtin";
    }

    // The --applied flags wallpaper-delete refuses: one pair per image path in `paths`, in order. Empty values and
    // colour backdrops, which start with "#", name no file.
    function appliedArgs(paths) {
        return (paths || []).filter(path => !!path && !String(path).startsWith("#")).reduce((args, path) => args.concat(["--applied", String(path)]), []);
    }
    // END WALLPAPER MEMBERSHIP DECISION

    // The All-view caption both wallpaper surfaces draw for an entry.
    function sourceTagFor(entry) {
        return root.sourceTag(entry, I18n.tr("My folder"));
    }

    // Sweep missing thumbnails in the background after publishing the list.
    // The all-themes scope also permits pruning entries absent from the complete wallpaper set.
    property bool _thumbSweepInFlight: false
    // Attempts per cache IDENTITY, not per path. `thumbKey` folds in the
    // source's size and mtime, so overwriting a wallpaper in place mints a new
    // key and earns fresh attempts, while the same failing file keeps its own
    // and stops. A path-keyed record could not tell those apart and refused to
    // rebuild a replaced file for the rest of the session.
    //
    // Bounded rather than one-shot: `wallpaper-thumbs` exits 0 when it built or
    // reused ANYTHING, so a per-file timeout or decode error rides back on a
    // success. Counting attempts is what retries that without trusting the exit
    // status, and what stops a genuinely undecodable file from sweeping forever.
    property var _thumbAttempts: ({})
    readonly property int _thumbMaxAttempts: 2
    // Set by the flows that DELETE a wallpaper; cleared when a sweep runs.
    property bool _thumbSweepWanted: false

    // Force the next sweep even when the CURRENT theme is fully cached. `--all`
    // both builds and prunes, so this covers each side: a removal orphans
    // thumbnails nothing would otherwise sweep, and an install adds a theme
    // whose wallpapers are missing but invisible from here — without this its
    // rail falls back to full-size sources until it is applied.
    // Public for the install side: VGSThemeCatalogService.install, raised from
    // the download offer after an apply, adds wallpapers outside this service.
    function requestThumbnailSweep() {
        root._thumbSweepWanted = true;
    }

    // BEGIN THUMBNAIL SWEEP DECISION
    // Keep sweep decisions independent of QML objects; every input is an argument. scripts/test-thumb-sweep.js evaluates the code between these markers in Node; nothing here may reference root, Theme, I18n, or Qt.

    // What a read should do. `attempts` is per cache IDENTITY, not per path:
    // overwriting a wallpaper mints a new key and earns fresh attempts, while
    // the same failing file keeps its own and stops. Identities confirmed to
    // carry a thumbnail are FORGOTTEN, so a deleted thumbnail or a replaced
    // source starts from zero; counts for entries this read cannot see — every
    // other theme — are kept, or switching themes would refund them.
    function thumbSweepPlan(entries, attempts, forced, maxAttempts) {
        const kept = {};
        for (const key in attempts)
            kept[key] = attempts[key];
        const missing = [];
        (entries || []).forEach(entry => {
            if (!entry || !entry.path)
                return;
            const key = String(entry.thumbKey || entry.path);
            if (entry.thumb)
                delete kept[key];
            else
                missing.push(key);
        });
        if (!forced && !missing.some(key => (kept[key] || 0) < maxAttempts))
            return {sweep: false, attempts: kept, missing: missing};
        const spent = {};
        for (const key in kept)
            spent[key] = kept[key];
        missing.forEach(key => spent[key] = (spent[key] || 0) + 1);
        return {sweep: true, attempts: spent, missing: missing};
    }

    // What a finished command means. Exit status alone does not say whether the
    // sweep RAN: the helper also exits non-zero when it completed and every
    // uncached wallpaper failed to decode, which is the normal answer with no
    // decoder installed. A parseable result is a COMPLETED sweep whatever it
    // exited with — counted against the cap and spending the request — while an
    // unparseable one restores the request and must not trigger a re-read, or a
    // broken command spins. Reported identities this dispatch already charged
    // are skipped, or one failed sweep would spend both attempts at once.
    function thumbSweepResult(output, missing, attempts, forced) {
        let parsed = null;
        try {
            parsed = JSON.parse(output || "");
        } catch (error) {
            parsed = null;
        }
        if (!parsed || !Array.isArray(parsed.failed))
            return {completed: false, attempts: attempts, restoreForced: !!forced, reread: false};
        const counted = {};
        for (const key in attempts)
            counted[key] = attempts[key];
        const charged = {};
        (missing || []).forEach(key => charged[key] = true);
        (parsed.failed || []).forEach(entry => {
            const key = entry && entry.key;
            if (key && !charged[key])
                counted[key] = (counted[key] || 0) + 1;
        });
        return {completed: true, attempts: counted, restoreForced: false, reread: true};
    }
    // END THUMBNAIL SWEEP DECISION

    function _sweepWallpaperThumbs() {
        if (root._thumbSweepInFlight)
            return;
        const forced = root._thumbSweepWanted;
        const plan = root.thumbSweepPlan(root.themeWallpapers || [], root._thumbAttempts,
                                         forced, root._thumbMaxAttempts);
        root._thumbAttempts = plan.attempts;
        if (!plan.sweep)
            return;
        root._thumbSweepWanted = false;
        root._thumbSweepInFlight = true;
        _run("vgs-theme-wallpaper-thumbs", ["theme", "wallpaper-thumbs", "--all", "--json"], function(output, exitCode) {
            root._thumbSweepInFlight = false;
            const outcome = root.thumbSweepResult(output, plan.missing, root._thumbAttempts, forced);
            root._thumbAttempts = outcome.attempts;
            if (outcome.restoreForced)
                root._thumbSweepWanted = true;
            if (outcome.reread)
                root.refreshWallpapers();
        }, 600000, true);
    }

    // A surface outside Settings passes `toast`: nothing there hears applyCompleted, so the outcome is toasted
    // here instead of announced, and a Settings tab that toasts applyCompleted cannot show it twice.
    function wallpaperAdd(path, toast) {
        if (!path)
            return;
        const theme = currentTheme.name || "";
        const report = (success, message) => {
            if (!toast)
                applyCompleted(success, message);
            else
                root._toastWallpaperOutcome(success, message);
        };
        _run("vgs-theme-wallpaper-add", ["theme", "wallpaper-add", path, "--json"].concat(theme ? ["--theme", theme] : []), function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                report(false, stderr || output || ("Wallpaper add failed: " + path));
                return;
            }
            refreshWallpapers();
            refreshAllWallpapers();
            refreshBlueprints();
            report(true, "Added wallpaper to " + (theme || "theme"));
        });
    }

    // Toast a wallpaper action's outcome on the surface that started it; nothing outside Settings hears applyCompleted.
    function _toastWallpaperOutcome(success, message) {
        if (success)
            ToastService.showInfo(message);
        else
            ToastService.showError(I18n.tr("VGS wallpaper error"), message);
    }

    // Take a wallpaper out of the applied theme's set. The file stays on disk and in the All list, unmarked.
    function wallpaperRemove(file) {
        if (!file)
            return;
        _run("vgs-theme-wallpaper-remove", ["theme", "wallpaper-remove", file, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                root._toastWallpaperOutcome(false, stderr || output || ("Wallpaper remove failed: " + file));
                return;
            }
            refreshWallpapers();
            refreshAllWallpapers();
            refreshBlueprints();
            root._toastWallpaperOutcome(true, "Removed " + file + " from " + (currentTheme.name || "theme"));
        });
    }

    // Delete a wallpaper file from disk. The helper refuses one the session or the lock screen still names, so a
    // mode switch, a reconnected monitor or a lock never draws a deleted file.
    function wallpaperDelete(path) {
        if (!path)
            return;
        const applied = root.appliedArgs(SessionData.referencedWallpapers().concat([SettingsData.lockScreenWallpaperPath]));
        _run("vgs-theme-wallpaper-delete", ["theme", "wallpaper-delete", path, "--folder", wallpaperFolderPath, "--json"].concat(applied), function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                root._toastWallpaperOutcome(false, stderr || output || ("Wallpaper delete failed: " + path));
                return;
            }
            root.requestThumbnailSweep();
            refreshWallpapers();
            refreshAllWallpapers();
            refreshBlueprints();
            root._toastWallpaperOutcome(true, "Deleted " + path.substring(path.lastIndexOf("/") + 1));
        });
    }

    function wallpaperDefault(file) {
        if (!file)
            return;
        _run("vgs-theme-wallpaper-default", ["theme", "wallpaper-default", file, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Set default failed: " + file));
                return;
            }
            refreshWallpapers();
            refreshBlueprints();
            applyCompleted(true, file + " is now the default wallpaper");
        });
    }

    // Returns the request id the completion will carry, or "" when nothing was
    // dispatched. A caller latching on the reply must check for "": there is no
    // completion coming for a request that was never made.
    // `offersDownload` is true only for a theme the user picked: a re-apply the
    // shell makes itself, after an icon setting change or a finished download,
    // must not ask again after the user answered Not now.
    function applyBlueprint(name, offersDownload) {
        if (!name)
            return "";
        const requestId = _beginApply("vgs-theme-apply-" + name);
        _runApply(requestId, ["theme", "apply", name, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                _finishApply(requestId, false, stderr || output || "Apply failed");
                return;
            }
            let data = {};
            try {
                data = JSON.parse(output || "{}");
            } catch (e) {
                _finishApply(requestId, false, "Failed to parse apply result: " + e);
                return;
            }
            // A throw raised AFTER the parse succeeded is not a parse failure,
            // and it must still finish the request: Proc only log.warns a
            // throwing callback, so an unfinished request pins `applyInFlight`
            // true and both switchers answer every Enter with "Still applying".
            // The SUCCESS resolves after the try, so a handler throwing back into
            // this frame cannot reach the catch.
            let message = "";
            try {
                const warnings = data.warnings || [];
                const appliedName = data.name || name;
                const details = [];
                if ((data.curated || []).length > 0)
                    details.push("curated: " + data.curated.join(", "));
                if ((data.skipped || []).length > 0)
                    details.push("off: " + data.skipped.join(", "));
                if (warnings.length > 0)
                    details.push("warnings: " + warnings.join("; "));
                // wallpaperSource=folder decouples the wallpaper from theme applies.
                const themeWallpaper = SettingsData.wallpaperSource !== "folder";
                if (data.wallpaper && !themeWallpaper)
                    details.push("wallpaper kept (theme wallpapers off)");
                lastMessage = "Applied " + appliedName + (details.length > 0 ? " · " + details.join(" · ") : "");
                _persistAppliedTheme(appliedName);
                if (data.wallpaper && typeof SessionData !== "undefined" && themeWallpaper)
                    SessionData.setWallpaper(data.wallpaper);
                _markGreeterThemeSyncPending();
                refreshCurrent();
                // The wallpaper set is theme-scoped: without this, every surface
                // reading `themeWallpapers` keeps the previous theme's list.
                refreshWallpapers();
                // Offered only after the colours landed, so the offer never holds up the apply.
                // With theme wallpapers off the user's own wallpaper stays, so there is nothing to offer.
                if (offersDownload === true && themeWallpaper) {
                    const listed = (blueprints || []).find(bp => bp.name === appliedName);
                    VGSThemeCatalogService.offerDownload(appliedName, listed ? listed.installed : undefined);
                }
                message = lastMessage;
            } catch (e) {
                _finishApply(requestId, false, "Theme applied but the shell could not finish updating: " + e);
                return;
            }
            _finishApply(requestId, true, message);
        });
        return requestId;
    }

    // Returns the request id, or "" when nothing was dispatched — see
    // `applyBlueprint`.
    function setWallpaper(path, extractColors, mode) {
        if (!path)
            return "";
        // Optimistic, so the UI tracks the pending choice; restored below if the
        // helper refuses it, or the service claims a wallpaper that never landed.
        const previousWallpaper = selectedWallpaper;
        const args = ["theme", "set-wallpaper", path, "--json"];
        if (extractColors) {
            args.push("--extract");
            args.push("--scheme");
            args.push(SettingsData.matugenScheme || "scheme-tonal-spot");
            args.push("--contrast");
            args.push(String(SettingsData.matugenContrast || 0));
            args.push("--mode");
            args.push(mode || SettingsData.matugenMode || "auto");
        }
        const requestId = _beginApply("vgs-theme-wallpaper");
        selectedWallpaper = path;
        _wallpaperSlotOwner = requestId;
        _runApply(requestId, args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                _rollbackWallpaper(requestId, previousWallpaper);
                _finishApply(requestId, false, stderr || output || "Wallpaper apply failed");
                return;
            }
            let data = {};
            try {
                data = JSON.parse(output || "{}");
            } catch (e) {
                _rollbackWallpaper(requestId, previousWallpaper);
                lastError = "Failed to parse wallpaper result: " + e;
                _finishApply(requestId, false, lastError);
                return;
            }
            // Everything past the parse is guarded too: Proc only log.warns a
            // throwing callback, so a throw here would leave the request
            // unfinished and `applyInFlight` stuck true. The SUCCESS resolves
            // after the try, so a handler throwing back cannot reach the catch.
            let message = "";
            try {
                const warnings = data.warnings || data.apply?.warnings || [];
                if (data.saved)
                    _persistAppliedTheme(data.name || (data.apply && data.apply.name));
                // Every success commits, in dispatch order, so what `session.json`
                // holds is the last apply that landed. The ownership test that
                // used to gate this was written for OVERLAPPING applies, where a
                // late reply from an older one could overwrite a newer; one apply
                // at a time removed that premise, and the test then suppressed
                // the write whenever a later pick was still queued, leaving the
                // desktop on the image before this one while the palette came
                // from this one.
                if (typeof SessionData !== "undefined")
                    SessionData.setWallpaper(path);
                _markGreeterThemeSyncPending();
                refresh();
                const base = extractColors ? "Wallpaper colors generated and applied" : "Wallpaper applied";
                message = warnings.length > 0 ? base + " (warnings: " + warnings.join("; ") + ")" : base;
            } catch (e) {
                _finishApply(requestId, false, "Wallpaper applied but the shell could not finish updating: " + e);
                return;
            }
            _finishApply(requestId, true, message);
        });
        return requestId;
    }

    // True while `requestId` is still the newest apply to have claimed
    // `selectedWallpaper`. A request claims it when it is MADE, so a queued
    // later pick owns the slot while an earlier one is still running: that is
    // what stops the earlier one's failure rolling the highlight back off the
    // pick the user has already moved to. A mid-apply `refreshCurrent` cannot
    // void it either, since it is keyed on the request and never the path.
    function _ownsWallpaperSlot(requestId) {
        return _wallpaperSlotOwner === requestId;
    }

    // Undoes one optimistic `selectedWallpaper` write, but only while that call
    // still owns the slot: a refusal must not take the highlight off a later
    // pick that is still queued behind it. The desktop is untouched either way —
    // `session.json` is written only by a success.
    function _rollbackWallpaper(requestId, previousWallpaper) {
        if (_ownsWallpaperSlot(requestId))
            selectedWallpaper = previousWallpaper;
    }

    // The blueprint entry for the active theme (carries modified/builtin/
    // adjustments/appOverrides). Empty object when the current theme matches no
    // blueprint (legacy/manual), which the settings pages treat as unmodified.
    readonly property var currentBlueprint: {
        const name = currentTheme.name || "";
        const list = blueprints || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].name === name)
                return list[i];
        }
        return ({});
    }

    // Build the repeated `--set role=hex` args from a camelCase colors map,
    // returning {args, count} so callers can gate on how many roles were set.
    function _paletteSetArgs(colors) {
        const args = [];
        let count = 0;
        for (const key in paletteArgMap) {
            const value = colors ? colors[key] : "";
            if (value) {
                args.push("--set");
                args.push(paletteArgMap[key] + "=" + value);
                count++;
            }
        }
        return { args: args, count: count };
    }

    function applyColors(colors, name, mode, wallpaper, saveNow) {
        const args = ["theme", "apply-colors", "--name", name || (currentTheme.name || "manual-theme"), "--json"];
        const selectedMode = mode || currentTheme.mode || "dark";
        if (selectedMode === "light" || selectedMode === "dark") {
            args.push("--mode");
            args.push(selectedMode);
        }
        if (wallpaper) {
            args.push("--wallpaper");
            args.push(wallpaper);
        }
        if (saveNow)
            args.push("--save");
        Array.prototype.push.apply(args, _paletteSetArgs(colors).args);
        _run("vgs-theme-apply-colors", args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || "Manual palette apply failed");
                return;
            }
            let data = {};
            try {
                data = JSON.parse(output || "{}");
            } catch (e) {
                lastError = "Failed to parse manual palette result: " + e;
                applyCompleted(false, lastError);
                return;
            }
            const warnings = data.warnings || [];
            if (saveNow || data.saved)
                _persistAppliedTheme(data.name || name || currentTheme.name);
            _markGreeterThemeSyncPending();
            refresh();
            const base = saveNow ? "Manual palette applied and saved" : "Manual palette applied";
            applyCompleted(true, warnings.length > 0 ? base + " (warnings: " + warnings.join("; ") + ")" : base);
        });
    }

    // Live palette editing: apply one or more role edits and persist them into
    // the current theme's user overlay colors.toml (built-ins stay pristine in
    // the repo; revertTheme drops the overlay).
    function applyColorEdits(colors) {
        const set = _paletteSetArgs(colors);
        if (set.count === 0)
            return;
        const count = set.count;
        const args = ["theme", "apply-colors", "--persist", "--json"].concat(set.args);
        _run("vgs-theme-edit-colors", args, function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || "Color edit failed");
                return;
            }
            _markGreeterThemeSyncPending();
            refresh();
            applyCompleted(true, count === 1 ? "Color updated" : count + " colors updated");
        });
    }

    function revertTheme(name) {
        if (!name)
            return;
        _run("vgs-theme-revert", ["theme", "revert", name, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Revert failed: " + name));
                return;
            }
            _markGreeterThemeSyncPending();
            refresh();
            applyCompleted(true, name + " reverted to default");
        });
    }

    // Restyle requests are serialized latest-wins. A slider release while the
    // helper is active replaces the one waiting request instead of starting a
    // concurrent apply that could finish out of order.
    function _submitRestyleRequest(request) {
        const transition = RestyleQueue.submit(_restyleQueueState, request);
        _restyleQueueState = transition.state;
        if (transition.startRequest)
            _startRestyleRequest(transition.startRequest);
    }

    function _startRestyleRequest(request) {
        const reset = request && request.reset === true;
        const preview = request && request.preview === true;
        const args = ThemeRequest.restyleArgs(request);
        _run("vgs-theme-restyle", args, function(output, exitCode, stderr) {
            const transition = RestyleQueue.complete(_restyleQueueState, exitCode === 0);
            _restyleQueueState = transition.state;
            const policy = ThemeRequest.completionPolicy(request, transition, exitCode === 0);

            if (policy.markGreeter)
                _markGreeterThemeSyncPending();

            // Do not refresh or announce a superseded result: the next helper
            // run is the only state the sliders asked to keep.
            if (transition.startRequest) {
                _startRestyleRequest(transition.startRequest);
                return;
            }

            if (policy.refresh)
                refresh();
            if (exitCode !== 0) {
                if (!preview)
                    applyCompleted(false, stderr || output || (reset ? "Restyle reset failed" : "Restyle failed"));
                return;
            }
            if (policy.announce)
                applyCompleted(true, reset ? "Restyle adjustments cleared" : "Palette restyled");
        }, 120000, true);
    }

    // adjustments: {brightness, vibrancy, contrast, hue, temperature} ints, 0 neutral.
    // Stored non-destructively on the theme.
    function restyle(adjustments) {
        const normalized = ThemeRequest.normalizeAdjustments(adjustments);
        _submitRestyleRequest({ reset: false, preview: false, adjustments: normalized });
    }

    // Lightweight shell-only rendering for fluid feedback while a slider is
    // moving. It neither persists adjustments nor regenerates app targets.
    function previewRestyle(adjustments) {
        const normalized = ThemeRequest.normalizeAdjustments(adjustments);
        _submitRestyleRequest({ reset: false, preview: true, adjustments: normalized });
    }

    function resetRestyle() {
        _submitRestyleRequest({ reset: true });
    }

    function fetchAppRoles(app) {
        if (!app)
            return;
        _run("vgs-theme-app-roles-" + app, ["theme", "app-roles", app, "--json"], function(output, exitCode) {
            if (exitCode !== 0)
                return;
            try {
                const data = JSON.parse(output || "{}");
                const next = Object.assign({}, appRoles);
                // Store the full view: roles (template apps) + curatedColors (curated apps).
                next[app] = {
                    roles: data.roles || [],
                    curated: data.curated === true,
                    curatedColors: data.curatedColors || [],
                    curatedFile: data.curatedFile || ""
                };
                appRoles = next;
                appRolesLoaded(app);
            } catch (e) {
                lastError = "Failed to parse app roles: " + e;
            }
        });
    }

    function setAppColor(app, role, hex) {
        if (!app || !role || !hex)
            return;
        _run("vgs-theme-app-colors-" + app, ["theme", "app-colors", app, "--set", role + "=" + hex, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Override failed: " + app));
                return;
            }
            fetchAppRoles(app);
            refreshCurrent();
            refreshBlueprints();
            applyCompleted(true, _messageWithApplyWarnings(app + " " + role + " overridden", output));
        });
    }

    // Recolor a curated app file: replace every use of one hex with another
    // (deduped recolor-all), writing the theme's overlay curated file.
    function recolorApp(app, fromHex, toHex) {
        if (!app || !fromHex || !toHex)
            return;
        _run("vgs-theme-recolor-" + app, ["theme", "app-curated-recolor", app, "--set", fromHex + "=" + toHex, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Recolor failed: " + app));
                return;
            }
            fetchAppRoles(app);
            refreshCurrent();
            refreshBlueprints();
            applyCompleted(true, _messageWithApplyWarnings(app + " recolored", output));
        });
    }

    function resetAppColors(app) {
        if (!app)
            return;
        _run("vgs-theme-app-colors-" + app, ["theme", "app-colors", app, "--reset", "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Override reset failed: " + app));
                return;
            }
            fetchAppRoles(app);
            refreshCurrent();
            refreshBlueprints();
            applyCompleted(true, _messageWithApplyWarnings(app + " color overrides cleared", output));
        });
    }

    function clearWallpaper() {
        selectedWallpaper = "";
        // Releases the slot so nothing rolls the highlight back off the clear.
        _wallpaperSlotOwner = "";
        _run("vgs-theme-clear-wallpaper", ["theme", "clear-wallpaper", "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || "Wallpaper clear failed");
                return;
            }
            try {
                JSON.parse(output || "{}");
            } catch (e) {
                lastError = "Failed to parse wallpaper clear result: " + e;
                applyCompleted(false, lastError);
                return;
            }
            if (typeof SessionData !== "undefined")
                SessionData.clearWallpaper();
            _markGreeterThemeSyncPending();
            refresh();
            applyCompleted(true, "Wallpaper cleared");
        });
    }

    function saveCurrent(name) {
        if (!name)
            return;
        _run("vgs-theme-save-current", ["theme", "save-current", "--name", name, "--json"], function(output, exitCode) {
            if (exitCode !== 0) {
                applyCompleted(false, output || "Save failed");
                return;
            }
            refreshBlueprints();
            applyCompleted(true, "Saved " + name);
        });
    }

    // Which theme.json change `Theme`'s watcher saw while this ran. `repaired` names the
    // files `repair_theme_state` rewrote. An answer this cannot read is `unreadable`
    // rather than `clean`, because `clean` releases a session write that reaches every
    // monitor and that session.json cannot be repaired back from.
    function _themeInitOutcome(output, exitCode) {
        if (exitCode !== 0)
            return "unreadable";
        try {
            const repaired = JSON.parse(output || "{}").repaired;
            if (!Array.isArray(repaired)) {
                log.warn("theme init answered without a repaired list");
                return "unreadable";
            }
            return repaired.indexOf("theme.json") === -1 ? "clean" : "repaired";
        } catch (e) {
            log.warn("Could not read the theme init answer:", e.message);
            return "unreadable";
        }
    }

    // Reading the current theme never applies one, so a first run with no
    // theme.json needs this explicit step before the reads. The reads run
    // whatever init answers. init also repairs theme.json, which reaches `Theme`
    // as a file change partway through this run, so the arm is taken before the
    // launch. scripts/test-theme-startup.js executes this handler.
    Component.onCompleted: {
        Theme.themeInitStarted();
        try {
            _run("vgs-theme-init", ["theme", "init", "--json"], function(output, exitCode) {
                Theme.themeInitFinished(_themeInitOutcome(output, exitCode));
                refresh();
            }, 120000, true);
        } catch (e) {
            // What this covers is a synchronous failure before the run is armed, which
            // answers no callback; an arm nothing clears holds the theme sync for the
            // rest of the session. A run that is armed and never starts belongs to
            // Common/Proc.qml's timeout, which answers the callback itself.
            log.warn("Could not start theme init:", e);
            Theme.themeInitFinished("unreadable");
            refresh();
        }
    }
}
