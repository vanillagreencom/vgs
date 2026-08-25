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
    // A failed list/wallpapers read leaves the corresponding array empty, which
    // reads identically to a genuinely empty set. UI that asserts "you have
    // none" must check these first.
    //
    // Each flag carries its OWN error text. `lastError` is a shared slot that
    // every `_run` clears at dispatch and overwrites in its callback, so a
    // surface that fires four commands and then reads `lastError` renders
    // whichever one failed LAST — and watches it mutate, or blank out, under the
    // user. These are written only by the read that owns the flag.
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
    // Per-app template roles keyed by app id: [{role, value, overridden}]
    property var appRoles: ({})

    signal blueprintsLoaded
    signal currentLoaded
    signal themeAppsLoaded
    signal wallpapersLoaded
    signal appRolesLoaded(string app)
    signal applyCompleted(bool success, string message)
    // The SAME completion, carrying the id of the request it answers. A surface
    // that started one apply and wants to report only that apply's outcome
    // cannot use `applyCompleted`: 19 unrelated operations emit it from over 40
    // sites, so "the next one" is whichever command happened to land first.
    // Emitted only by `_finishApply`, which `applyBlueprint`/`setWallpaper` —
    // the two a switcher starts — are the only callers of.
    signal applyFinished(string requestId, bool success, string message)

    // Apply requests still running, keyed by a request id that is unique per
    // CALL. Deliberately narrower than `busy`: `busy` counts every non-background
    // command, so gating a switcher's Enter on it blocks while an unrelated
    // `theme restyle` or per-app override from a settings tab runs, and unblocks
    // while the switcher's own background reads are still in flight.
    property var _applyInFlight: ({})
    readonly property bool applyInFlight: Object.keys(_applyInFlight).length > 0
    // Monotonic, so no two calls ever share a request id. A NAME is not an
    // identity — `setWallpaper` uses one constant for every wallpaper — so two
    // overlapping calls shared a key and the first completion emptied the set.
    property int _applyRequestSeq: 0
    // The apply request that last claimed `selectedWallpaper`, or "" when none
    // does. Keyed on the REQUEST, never the path — see `_ownsWallpaperSlot`.
    property string _wallpaperSlotOwner: ""

    // `label` only makes the returned request id readable; it is NOT a Proc id
    // — see `_runApply`. Every apply answers its own callback, so a token leaves
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

    // backgroundTask: long-running helper calls (preview rendering) must not
    // count toward `busy`, or every Apply button goes dead for minutes.
    // `id` is this call's bookkeeping key in `_pending`; `procId` is the id Proc
    // COALESCES on and defaults to it — `_runApply` is the one caller that
    // wants them different.
    function _run(id, args, callback, timeoutMs, backgroundTask, procId) {
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

    // An apply, run under its own request id and coalesced with nothing. Proc's
    // debouncer folds same-id calls into ONE callback, and only within its window
    // — applies run at interval 0, so it catches same-tick calls and nothing else,
    // while two applies from separate key presses both launch and both answer. An
    // EMPTY Proc id makes Proc mint a random, self-cleaning id, so every apply
    // runs its own process into one `_finishApply`; a unique NAMED id would leak
    // a debouncer entry and Timer, reaped only for a random id.
    function _runApply(requestId, args, callback) {
        _run(requestId, args, callback, undefined, false, "");
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
            root.requestThumbnailPrune();
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

    function regeneratePreview(name) {
        if (!name || previewsGenerating)
            return;
        previewsGenerating = true;
        _run("vgs-theme-preview-one", ["theme", "preview", name, "--force", "--json"], function(output, exitCode) {
            previewsGenerating = false;
            if (exitCode !== 0) {
                applyCompleted(false, lastError || ("Preview generation failed: " + name));
                return;
            }
            refreshBlueprints();
            applyCompleted(true, "Preview regenerated for " + name);
        }, 600000, true);
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

    // One sweep per session, and only when an entry is actually missing its
    // thumbnail. Dispatched AFTER the list is published, as a background task,
    // so opening the switcher never waits on it: the rail falls back to the
    // originals meanwhile and simply gets faster once the sweep lands.
    //
    // `--all` covers every installed theme, not just the current one, so
    // switching themes does not pay a fresh decode; it also prunes entries no
    // wallpaper claims any more, which is only correct over the complete set.
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
    property bool _thumbPruneWanted: false

    // Ask the next sweep to run even when nothing is MISSING, so `--all` prunes
    // thumbnails whose wallpaper is gone. Public because removal happens from
    // more than one place: a wallpaper, a theme, and the catalog browser, which
    // owns its own service.
    function requestThumbnailPrune() {
        root._thumbPruneWanted = true;
    }

    function _sweepWallpaperThumbs() {
        if (root._thumbSweepInFlight)
            return;
        const entries = root.themeWallpapers || [];
        const identity = entry => String(entry.thumbKey || entry.path);
        // Clear ONLY identities this read confirmed carry a thumbnail, and keep
        // every other count. `entries` is the current theme while the sweep is
        // `--all`, so rebuilding the map from it would drop the counts of every
        // theme not selected: a decoder that times out on one wallpaper would
        // earn its attempts back each time the user returned to that theme.
        // A cleared identity starts from zero again, which is what lets a
        // deleted thumbnail or a replaced source be rebuilt.
        const kept = Object.assign({}, root._thumbAttempts);
        const missing = [];
        entries.forEach(entry => {
            if (!entry || !entry.path)
                return;
            const key = identity(entry);
            if (entry.thumb)
                delete kept[key];
            else
                missing.push(key);
        });
        root._thumbAttempts = kept;
        // A removal leaves the departed wallpaper's thumbnail behind, and with
        // every surviving entry cached there is nothing MISSING to trigger a
        // sweep — so the orphan would outlive the session and every one after
        // it. `--all` prunes, so a removal asks for a sweep in its own right.
        const hadPrune = root._thumbPruneWanted;
        if (!hadPrune && !missing.some(key => (kept[key] || 0) < root._thumbMaxAttempts))
            return;
        // Consumed at DISPATCH so a removal that lands while this sweep is in
        // flight sets a fresh request the callback cannot swallow: that sweep
        // read the wallpaper set before the removal, so it did not prune it.
        root._thumbPruneWanted = false;
        const spent = Object.assign({}, kept);
        missing.forEach(key => spent[key] = (spent[key] || 0) + 1);
        root._thumbAttempts = spent;
        root._thumbSweepInFlight = true;
        _run("vgs-theme-wallpaper-thumbs", ["theme", "wallpaper-thumbs", "--all", "--json"], function(output, exitCode) {
            root._thumbSweepInFlight = false;
            // A failed sweep is not reported: the rail is already drawing from
            // the originals, which is correct, just slower. Re-reading is what
            // swaps the rail onto the thumbnails just built, and it is skipped
            // on failure so a broken command cannot spin.
            if (exitCode !== 0) {
                // Restored, not left cleared: a sweep that times out must not
                // spend the request, or a removal whose only sweep failed loses
                // its orphan for good once every surviving entry is cached.
                if (hadPrune)
                    root._thumbPruneWanted = true;
                return;
            }
            // Count the failures the sweep REPORTS, not just the ones visible in
            // the current theme. `--all` attempts every theme, so an undecodable
            // wallpaper in one the user is not looking at is never in
            // `themeWallpapers` and would otherwise never reach the attempt cap
            // — running its decoder rungs again on every later sweep.
            try {
                const reported = (JSON.parse(output || "{}").failed || []);
                if (reported.length > 0) {
                    const counted = Object.assign({}, root._thumbAttempts);
                    // Only identities this dispatch did NOT already charge:
                    // a current-theme entry is counted once before dispatch, and
                    // counting it again here spent both attempts on one sweep, so
                    // the promised retry never ran.
                    const charged = {};
                    missing.forEach(key => charged[key] = true);
                    reported.forEach(entry => {
                        const key = entry && entry.key;
                        if (key && !charged[key])
                            counted[key] = (counted[key] || 0) + 1;
                    });
                    root._thumbAttempts = counted;
                }
            } catch (e) {
                // A sweep that answered with unparseable output still built what
                // it built; the per-theme counting above bounds the rest.
            }
            root.refreshWallpapers();
        }, 600000, true);
    }

    function wallpaperAdd(path) {
        if (!path)
            return;
        _run("vgs-theme-wallpaper-add", ["theme", "wallpaper-add", path, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Wallpaper add failed: " + path));
                return;
            }
            refreshWallpapers();
            refreshBlueprints();
            applyCompleted(true, "Added wallpaper to " + (currentTheme.name || "theme"));
        });
    }

    function wallpaperRemove(file) {
        if (!file)
            return;
        _run("vgs-theme-wallpaper-remove", ["theme", "wallpaper-remove", file, "--json"], function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                applyCompleted(false, stderr || output || ("Wallpaper remove failed: " + file));
                return;
            }
            root.requestThumbnailPrune();
            refreshWallpapers();
            refreshBlueprints();
            applyCompleted(true, "Removed " + file + " from " + (currentTheme.name || "theme"));
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
    function applyBlueprint(name) {
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
                if (data.wallpaper && SettingsData.wallpaperSource === "folder")
                    details.push("wallpaper kept (theme wallpapers off)");
                lastMessage = "Applied " + appliedName + (details.length > 0 ? " · " + details.join(" · ") : "");
                _persistAppliedTheme(appliedName);
                // wallpaperSource=folder decouples the wallpaper from theme applies.
                if (data.wallpaper && typeof SessionData !== "undefined" && SettingsData.wallpaperSource !== "folder")
                    SessionData.setWallpaper(data.wallpaper);
                _markGreeterThemeSyncPending();
                refreshCurrent();
                // The wallpaper set is theme-scoped: without this, every surface
                // reading `themeWallpapers` keeps the previous theme's list.
                refreshWallpapers();
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
                // Same ownership test the rollback uses: a LATE success from an
                // apply that no longer owns the slot must not persist its
                // wallpaper over a newer one that already moved the desktop on.
                // `refresh()` restores `selectedWallpaper`, not SessionData.
                if (typeof SessionData !== "undefined" && _ownsWallpaperSlot(requestId))
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

    // True while `requestId` is still the apply that claimed `selectedWallpaper`.
    // Both the rollback and the success-path persist test it, so no late reply
    // writes over a newer apply, and a mid-apply `refreshCurrent` cannot void it.
    function _ownsWallpaperSlot(requestId) {
        return _wallpaperSlotOwner === requestId;
    }

    // Undoes one optimistic `setWallpaper` write, but only while that call still
    // owns the slot: a LATE failure from an older overlapping call must not
    // revert a newer apply that already succeeded and moved the desktop on.
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
        // Releases the slot: an in-flight apply must not persist over this clear.
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

    property bool previewsGenerating: false

    function generateMissingPreviews() {
        if (previewsGenerating)
            return;
        // Claim the slot BEFORE any async work: preview generation stages a
        // nested-compositor VGSPREVIEW output, and two overlapping runs crash
        // quickshell ("removal for monitor VGSPREVIEW which was not previously
        // tracked" -> fatal Wayland error). Callers fire this from both
        // Component.onCompleted and onActiveChanged, so the guard must be set
        // synchronously to guarantee single-flight.
        previewsGenerating = true;
        // Re-read blueprints first so the "missing" check runs on fresh preview
        // paths (wallpaper/palette edits invalidate cached previews).
        // This read does NOT own `blueprintsLoadFailed`. That flag is how a
        // surface says "the theme list could not be read", and `refreshBlueprints`
        // is the read that backs the list; setting it from here reported a failed
        // PREVIEW probe as a failed list even when the list was loaded and on
        // screen. Failing here just means no previews were rendered this round.
        _run("vgs-theme-preview-check", ["theme", "list", "--json"], function(output, exitCode) {
            if (exitCode !== 0) {
                log.warn("Preview check failed, previews not refreshed:", lastError);
                previewsGenerating = false;
                return;
            }
            let bps;
            try {
                bps = JSON.parse(output || "{}").blueprints || [];
            } catch (e) {
                log.warn("Preview check returned unparseable blueprints:", e);
                previewsGenerating = false;
                return;
            }
            blueprints = bps;
            blueprintsLoadFailed = false;
            blueprintsLoadError = "";
            blueprintsLoaded();
            if (!bps.some(bp => !bp.preview)) {
                previewsGenerating = false;
                return;
            }
            // One helper invocation renders every missing preview under a single
            // hidden nested compositor rule; cached entries are skipped inside.
            _run("vgs-theme-preview-all", ["theme", "preview", "--all", "--json"], function(o, ec) {
                previewsGenerating = false;
                if (ec !== 0)
                    log.warn("Theme preview generation failed:", lastError);
                refreshBlueprints();
            }, 600000, true);
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

    Component.onCompleted: refresh()
}
