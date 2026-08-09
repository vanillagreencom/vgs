pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("PluginService")

    property var availablePlugins: ({})
    property var loadedPlugins: ({})
    property var pluginWidgetComponents: ({})
    property var pluginDaemonComponents: ({})
    property var pluginLauncherComponents: ({})
    property var pluginDesktopComponents: ({})
    property var availablePluginsList: []
    readonly property string userPluginDirectory: Paths.strip(Paths.config) + "/plugins"
    readonly property string pluginDirectory: userPluginDirectory
    readonly property string bundledPluginDirectory: Paths.repoRoot + "/config/vshell/plugins"

    property bool pluginDirectoryExists: false
    property string systemPluginDirectory: "/etc/xdg/quickshell/vshell/plugins"

    property var knownManifests: ({})
    property var pathToPluginId: ({})
    // Ids seen from the bundled directory, whether or not a higher-priority
    // source currently owns them. Gates the always-available invariant.
    property var _bundledPluginIds: ({})
    // Public, reactive view of the same map. UI binds this so it can tell an
    // always-available VGS module from a third-party plugin instead of offering
    // controls that cannot succeed.
    readonly property var bundledPluginIds: _bundledPluginIds
    // Collision reports are one-per-id-per-source for the process; a rescan of
    // the same colliding package must not re-toast.
    property var _reportedCollisions: ({})
    property var pluginInstances: ({})
    // Daemon-surface plugins are instantiated by the shell's daemon Instantiator
    // (VGS.qml), which owns their lifetime. Registering the live item here lets
    // callers reach that same instance instead of creating a second one, which
    // would duplicate any IpcHandler the plugin declares.
    property var daemonInstances: ({})
    property var globalVars: ({})
    property var pluginLoadErrors: ({})

    property var _stateCache: ({})
    property var _stateLoaded: ({})
    property var _stateWriters: ({})
    property var _stateDirtyPlugins: ({})
    property bool _stateDirCreated: false

    signal pluginLoaded(string pluginId)
    signal pluginUnloaded(string pluginId)
    signal pluginLoadFailed(string pluginId, string error)
    signal pluginDataChanged(string pluginId)
    signal pluginStateChanged(string pluginId)
    signal pluginListUpdated
    signal globalVarChanged(string pluginId, string varName)
    signal requestLauncherUpdate(string pluginId)

    Timer {
        id: resyncDebounce
        interval: 120
        repeat: false
        onTriggered: resyncAll()
    }

    Timer {
        id: _stateWriteTimer
        interval: 150
        repeat: false
        onTriggered: root._flushDirtyStates()
    }

    Process {
        id: directoryCheckProcess
        command: ["test", "-d", root.pluginDirectory]
        onExited: (exitCode) => {
            root.pluginDirectoryExists = (exitCode === 0);
        }
    }

    function checkPluginDirectoryExists() {
        directoryCheckProcess.running = true;
    }

    Component.onCompleted: {
        userWatcher.folder = Paths.toFileUrl(root.pluginDirectory);
        bundledWatcher.folder = Paths.toFileUrl(root.bundledPluginDirectory);
        systemWatcher.folder = Paths.toFileUrl(root.systemPluginDirectory);
        Qt.callLater(resyncAll);
        Qt.callLater(checkPluginDirectoryExists);
    }

    FolderListModel {
        id: userWatcher
        showDirs: true
        showFiles: false
        showDotAndDotDot: false

        onCountChanged: resyncDebounce.restart()
        onStatusChanged: {
            if (status === FolderListModel.Ready)
                resyncDebounce.restart();
        }
    }

    FolderListModel {
        id: bundledWatcher
        showDirs: true
        showFiles: false
        showDotAndDotDot: false

        onCountChanged: resyncDebounce.restart()
        onStatusChanged: {
            if (status === FolderListModel.Ready)
                resyncDebounce.restart();
        }
    }

    FolderListModel {
        id: systemWatcher
        showDirs: true
        showFiles: false
        showDotAndDotDot: false

        onCountChanged: resyncDebounce.restart()
        onStatusChanged: {
            if (status === FolderListModel.Ready)
                resyncDebounce.restart();
        }
    }

    function _sourcePriority(sourceTag) {
        if (sourceTag === "user")
            return 30;
        if (sourceTag === "bundled")
            return 20;
        if (sourceTag === "system")
            return 10;
        return 0;
    }

    function _sourceBaseDir(sourceTag) {
        if (sourceTag === "user")
            return pluginDirectory;
        if (sourceTag === "bundled")
            return bundledPluginDirectory;
        return systemPluginDirectory;
    }

    function snapshotModel(model, sourceTag) {
        const out = [];
        const n = model.count;
        const baseDir = _sourceBaseDir(sourceTag);
        for (let i = 0; i < n; i++) {
            let dirPath = model.get(i, "filePath");
            if (dirPath.startsWith("file://")) {
                dirPath = dirPath.substring(7);
            }
            if (!dirPath.startsWith(baseDir)) {
                continue;
            }
            const manifestPath = dirPath + "/plugin.json";
            out.push({
                path: manifestPath,
                source: sourceTag
            });
        }
        return out;
    }

    function resyncAll() {
        const userList = snapshotModel(userWatcher, "user");
        const bundledList = snapshotModel(bundledWatcher, "bundled");
        const sysList = snapshotModel(systemWatcher, "system");
        const seenPaths = {};

        function consider(entry) {
            const key = entry.path;
            seenPaths[key] = true;
            const prev = knownManifests[key];
            if (!prev) {
                loadPluginManifestFile(entry.path, entry.source, Date.now());
            }
        }
        for (let i = 0; i < sysList.length; i++)
            consider(sysList[i]);
        for (let i = 0; i < bundledList.length; i++)
            consider(bundledList[i]);
        for (let i = 0; i < userList.length; i++)
            consider(userList[i]);

        const removed = [];
        const removedPluginIds = {};
        for (const path in knownManifests) {
            if (!seenPaths[path])
                removed.push(path);
        }
        if (removed.length) {
            removed.forEach(function (path) {
                const pid = pathToPluginId[path];
                if (pid) {
                    removedPluginIds[pid] = true;
                    unregisterPluginByPath(path, pid);
                }
                delete knownManifests[path];
                delete pathToPluginId[path];
            });
            for (const pid in removedPluginIds) {
                const wasBundled = _bundledPluginIds[pid] === true;
                // Before promoting: a removed bundled manifest must stop
                // marking the id always-available, or a same-id user package
                // stays auto-enabled and undisableable for the process
                // lifetime, and stays blocked from being promoted at all.
                _refreshBundledId(pid);
                if (availablePlugins[pid])
                    continue;
                // A product id that ends up with no owner is a collision that
                // ended in nothing loaded. It must never be silent — and the
                // promotion decides that asynchronously, so the report waits
                // for it rather than for the read to start. (VGS-75)
                promoteShadowedPlugin(pid, function (ok) {
                    if (wasBundled && !ok)
                        root._reportIdLeftEmpty(pid);
                });
            }
            _updateAvailablePluginsList();
            pluginListUpdated();
        }
    }

    // Returns whether a candidate was found and its (asynchronous) load
    // started. Callers must not read availablePlugins to answer that question:
    // loadPluginManifestFile parses through a FileView, so the id is still
    // unowned when this returns. "No candidate at all" is the only synchronous,
    // reliable signal that the id is about to be left empty. (VGS-75)
    //
    // The return value is therefore NOT an outcome, and no caller may report
    // one from it: the candidate can still fail to parse, be invalid, lose the
    // id to another package, or fail its startup gate, and a caller that told
    // the user "the bundled version is still in use" on the strength of a
    // started read would be describing a plugin that never loaded. Pass
    // `onSettled(ok)` and say nothing until it fires — see _beginPromotion.
    //
    // `continuesPath` is the manifest path of the record this promotion is
    // superseding, when there is one. It is what lets _beginPromotion tell a
    // chained retry from an unrelated second promotion of the same id.
    function promoteShadowedPlugin(pluginId, onSettled, continuesPath) {
        let bestPath = "";
        let bestSource = "";
        let bestPriority = -1;
        for (const path in knownManifests) {
            if (pathToPluginId[path] !== pluginId)
                continue;
            const meta = knownManifests[path];
            // `blocked` is a package that only collided with a bundled id and
            // never claimed it; `demoted` is an override that claimed one and
            // failed to load. Promoting either would undo the decision that set
            // the flag, so only the shipped package is eligible.
            if (!meta || meta.bad || meta.blocked || meta.demoted)
                continue;
            const priority = _sourcePriority(meta.source);
            if (priority > bestPriority) {
                bestPath = path;
                bestSource = meta.source;
                bestPriority = priority;
            }
        }
        if (!bestPath) {
            // The one synchronous verdict this function can give, and it is a
            // final one: with no candidate there is nothing left to settle.
            if (onSettled)
                onSettled(false);
            return false;
        }
        delete knownManifests[bestPath];
        _beginPromotion(pluginId, bestPath, onSettled, continuesPath);
        loadPluginManifestFile(bestPath, bestSource, Date.now());
        return true;
    }

    // Promotions whose manifest read has started and whose outcome is not known
    // yet, by plugin id. Entry: { path, onSettled, deadline }.
    property var _pendingPromotions: ({})

    // How long a promotion may stay unsettled before it is judged. A promotion
    // is a manifest read followed, usually, by a startup gate that can spawn a
    // process, so it is not instant — but it has to be bounded, because the
    // whole point of tracking it is that a promotion ending with nothing loaded
    // must reach the user. Same shape as appLauncherRegistrationTimeout, with a
    // budget that accommodates a startupCheck.
    readonly property int _promotionTimeoutMs: 8000

    // Two different situations can start a promotion for an id that already has
    // one pending, and collapsing them is what silently dropped a reporter:
    //
    //   * a CONTINUATION — the pending promotion's own candidate reached the
    //     load path and failed, so _demoteToShipped promotes the next one. Both
    //     reporters describe one event stream, and the user wants its outcome
    //     once, not one line per hop.
    //   * an INDEPENDENT second promotion — resyncAll promoting a removed
    //     bundled id while a demotion for the same id is in flight, say. Two
    //     callers are asking two different questions ("was the shipped module
    //     restored?" and "is this product id empty?") and each is entitled to
    //     its answer.
    //
    // The two are told apart by fact, not by heuristic: a continuation names
    // the record it is superseding, and it is a continuation only if that is
    // exactly what the pending promotion produced. `chain` therefore holds at
    // most one reporter however long the chain runs, while `others` grows only
    // for genuinely independent callers — so the chained case still yields one
    // user-visible message, and a race yields one per caller instead of losing
    // one. (VGS-75)
    function _beginPromotion(pluginId, manifestPath, onSettled, continuesPath) {
        const prev = _pendingPromotions[pluginId];
        let chain = prev ? prev.chain : null;
        let others = prev ? prev.others : [];
        if (!prev) {
            chain = onSettled || null;
            others = [];
        } else if (continuesPath && prev.path === continuesPath) {
            // Supersedes the pending reporter rather than joining it: the newer
            // one knows the most recent failure and the package that ended up
            // running, which is what the settled message has to describe.
            chain = onSettled || prev.chain;
        } else if (onSettled && onSettled !== chain && others.indexOf(onSettled) === -1) {
            others = others.concat([onSettled]);
        }
        const next = Object.assign({}, _pendingPromotions);
        next[pluginId] = {
            path: manifestPath,
            chain: chain,
            others: others,
            deadline: Date.now() + _promotionTimeoutMs
        };
        _pendingPromotions = next;
        promotionSweep.start();
    }

    function _settlePromotion(pluginId, ok) {
        const entry = _pendingPromotions[pluginId];
        if (!entry)
            return;
        const next = Object.assign({}, _pendingPromotions);
        delete next[pluginId];
        _pendingPromotions = next;
        if (!Object.keys(_pendingPromotions).length)
            promotionSweep.stop();
        const settled = ok === true;
        // After the entry is gone, so a reporter that starts another promotion
        // for the same id builds a fresh one instead of mutating the one being
        // settled.
        if (entry.chain)
            entry.chain(settled);
        for (let i = 0; i < entry.others.length; i++)
            entry.others[i](settled);
    }

    // A load that succeeds is the success signal for whatever promotion was
    // waiting on this id — including a promotion whose candidate reached the
    // load path some hops later.
    onPluginLoaded: pluginId => root._settlePromotion(pluginId, true)

    // Every other outcome is judged here, on a deadline. Deliberately no
    // per-branch failure verdicts: a bad parse, a lost arbitration or a failed
    // gate for one manifest does not prove the id ends up empty, because
    // another read for the same id can still be in flight. The deadline asks
    // the only question that cannot be wrong — "is something loaded for this id
    // now?" — at a bounded time, so a promotion can never end in silence.
    Timer {
        id: promotionSweep
        interval: 1000
        repeat: true
        running: false
        onTriggered: root._sweepPromotions()
    }

    function _sweepPromotions() {
        const now = Date.now();
        const expired = [];
        for (const pluginId in _pendingPromotions) {
            if (_pendingPromotions[pluginId].deadline <= now)
                expired.push(pluginId);
        }
        for (let i = 0; i < expired.length; i++) {
            const pluginId = expired[i];
            const entry = _pendingPromotions[pluginId];
            const ok = isPluginLoaded(pluginId);
            if (!ok)
                log.error("promoted plugin manifest did not finish loading:", pluginId, entry.path);
            _settlePromotion(pluginId, ok);
        }
        if (!Object.keys(_pendingPromotions).length)
            promotionSweep.stop();
    }

    function loadPluginManifestFile(manifestPathNoScheme, sourceTag, mtimeEpochMs) {
        const loader = manifestFvComp.createObject(root, {
            absPath: manifestPathNoScheme,
            path: manifestPathNoScheme,
            sourceTag: sourceTag,
            mtimeEpochMs: mtimeEpochMs
        });
    }

    Component {
        id: manifestFvComp
        FileView {
            id: fv
            property string absPath: ""
            property string sourceTag: ""
            property double mtimeEpochMs: 0
            onLoaded: {
                try {
                    let raw = text();
                    if (raw.charCodeAt(0) === 0xFEFF)
                        raw = raw.slice(1);
                    const manifest = JSON.parse(raw);
                    root._onManifestParsed(absPath, manifest, sourceTag, mtimeEpochMs);
                } catch (e) {
                    root.log.error("bad manifest", absPath, e.message);
                    root.knownManifests[absPath] = {
                        mtime: mtimeEpochMs,
                        source: sourceTag,
                        bad: true
                    };
                }
                fv.destroy();
            }
            onLoadFailed: err => {
                root.log.warn("manifest load failed", absPath, err);
                fv.destroy();
            }
        }
    }

    readonly property var pluginSurfaceKeys: ["widget", "desktop", "daemon", "launcher"]

    function _stripDotSlash(p) {
        return p.startsWith("./") ? p.slice(2) : p;
    }

    function _deriveLegacySurface(type, capabilities) {
        if (type === "daemon")
            return "daemon";
        if (type === "launcher" || (capabilities && capabilities.includes("launcher")))
            return "launcher";
        if (type === "desktop")
            return "desktop";
        return "widget";
    }

    function _resolveComponentPaths(manifest, dir) {
        const paths = {};
        if (manifest.components && typeof manifest.components === "object") {
            for (const surface in manifest.components) {
                if (!pluginSurfaceKeys.includes(surface)) {
                    log.warn("unknown plugin surface", surface, "in", dir);
                    continue;
                }
                const rel = manifest.components[surface];
                if (!rel)
                    continue;
                paths[surface] = dir + "/" + _stripDotSlash(rel);
            }
            return paths;
        }
        if (manifest.component) {
            const surface = _deriveLegacySurface(manifest.type, manifest.capabilities);
            paths[surface] = dir + "/" + _stripDotSlash(manifest.component);
        }
        return paths;
    }

    function pluginHasSurface(pluginId, surface) {
        const plugin = availablePlugins[pluginId];
        return !!(plugin && plugin.surfaces && plugin.surfaces.includes(surface));
    }

    function _onManifestParsed(absPath, manifest, sourceTag, mtimeEpochMs) {
        if (!manifest || !manifest.id || !manifest.name || (!manifest.component && !manifest.components)) {
            log.error("invalid manifest fields:", absPath);
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
                bad: true
            };
            return;
        }

        const dir = absPath.substring(0, absPath.lastIndexOf('/'));
        let settings = manifest.settings;
        if (settings && settings.startsWith("./"))
            settings = settings.slice(2);
        let startupCheck = manifest.startupCheck;
        if (startupCheck && startupCheck.startsWith("./"))
            startupCheck = startupCheck.slice(2);

        const componentPaths = _resolveComponentPaths(manifest, dir);
        const surfaces = Object.keys(componentPaths);
        if (surfaces.length === 0) {
            log.error("no valid component surfaces in manifest:", absPath);
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
                bad: true
            };
            return;
        }

        const info = {};
        for (const k in manifest)
            info[k] = manifest[k];

        let perms = manifest.permissions;
        if (typeof perms === "string") {
            perms = perms.split(/\s*,\s*/);
        }
        if (!Array.isArray(perms)) {
            perms = [];
        }
        info.permissions = perms.map(p => String(p).trim());

        info.manifestPath = absPath;
        info.pluginDirectory = dir;
        info.componentPaths = componentPaths;
        info.surfaces = surfaces;
        info.componentPath = componentPaths.widget || componentPaths[surfaces[0]];
        info.settingsPath = settings ? (dir + "/" + settings) : null;
        info.startupCheckPath = startupCheck ? (dir + "/" + startupCheck) : null;
        info.loaded = isPluginLoaded(manifest.id);
        info.type = manifest.type || (manifest.components ? "composite" : "widget");
        info.source = sourceTag;
        info.requires_shell = manifest.requires_shell || manifest.requires_vgs || null;
        info.requires_vgs = info.requires_shell;
        if (sourceTag === "bundled")
            _auditBundledRequirement(manifest.id, info.requires_shell);

        // A bundled id names a VGS product module, and some of them back core
        // UI (the app launcher has no fallback since VGS-13). A user package
        // may still replace one, but that has to be a decision, not a name
        // collision — see _declaresBundledOverride.
        if (sourceTag === "bundled" && !_bundledPluginIds[manifest.id]) {
            const knownBundled = Object.assign({}, _bundledPluginIds);
            knownBundled[manifest.id] = true;
            _bundledPluginIds = knownBundled;
        }

        const existing = availablePlugins[manifest.id] || null;
        const decision = _bundledOverrideDecision({
            sourceTag: sourceTag,
            pluginId: manifest.id,
            manifest: manifest,
            bundledId: _bundledPluginIds[manifest.id] === true,
            existing: existing,
            isPureDesktop: surfaces.length === 1 && surfaces[0] === "desktop",
            userEnabled: SettingsData.getPluginSetting(manifest.id, "enabled", false) === true,
            incomingPriority: _sourcePriority(sourceTag),
            existingPriority: existing ? _sourcePriority(existing.source) : -1,
            incomingPath: absPath,
            existingPath: existing ? existing.manifestPath : ""
        });
        info.overridesBundled = decision.overridesBundled;
        info.alwaysAvailable = decision.alwaysAvailable;

        if (decision.action === "block") {
            // A package that merely reuses a shipped id stays inert: the shipped
            // package keeps the id, and nothing the user never enabled is
            // loaded on the strength of a name match. Declaring
            // `"overrides": "<id>"` is the opt-in. (VGS-26)
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
                requiresShell: info.requires_shell,
                blocked: "bundled"
            };
            pathToPluginId[absPath] = manifest.id;
            _reportBundledCollision(manifest.id, sourceTag);
            if (existing && existing.manifestPath === absPath) {
                // It owned the id before the bundled directory was known.
                // Promoting the shipped manifest re-enters this function for
                // it, which takes the id back through the reclaim path below —
                // gated, so the running package is not torn down first.
                promoteShadowedPlugin(manifest.id);
            }
            return;
        }

        if (decision.action !== "shadow") {
            if (decision.action === "reclaim") {
                const displacedMeta = knownManifests[existing.manifestPath];
                knownManifests[existing.manifestPath] = {
                    mtime: displacedMeta ? displacedMeta.mtime : mtimeEpochMs,
                    source: existing.source,
                    requiresShell: existing.requires_shell,
                    blocked: "bundled"
                };
                _reportBundledCollision(manifest.id, existing.source);
            }
            // The package this one displaces, if it is currently loaded. Its
            // teardown is deferred until the incoming package has passed its
            // own startup gate — unloading first is what left a product surface
            // with nothing loaded when an override turned out to be
            // non-viable. (VGS-24)
            const displaced = _displacesLoadedPackage(existing, absPath) ? existing : null;
            const newMap = Object.assign({}, availablePlugins);
            newMap[manifest.id] = info;
            availablePlugins = newMap;
            pathToPluginId[absPath] = manifest.id;
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
                requiresShell: info.requires_shell
            };
            if (displaced)
                info.loaded = false;
            else
                _relinkLoadedRecord(manifest.id, info, absPath);
            _updateAvailablePluginsList();
            pluginListUpdated();
            if (decision.enabled && !info.loaded) {
                // Gated whenever there is something to protect: a package still
                // loaded under this id, or a shipped package this one is
                // declaring itself the override of.
                if (displaced || (decision.overridesBundled && decision.alwaysAvailable))
                    _gateThenSwap(manifest.id, displaced);
                else
                    runStartupGate(manifest.id);
            } else if (displaced) {
                unloadPlugin(manifest.id);
            }
            // A record that inherited the loaded registration for its own path
            // has nothing to load, so it never emits pluginLoaded — but the id
            // *is* loaded, which is exactly what a promotion is waiting to
            // hear. (The shipped package that was never unloaded when an
            // override failed its gate takes this path.)
            if (info.loaded)
                _settlePromotion(manifest.id, true);
        } else {
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
                requiresShell: info.requires_shell,
                shadowedBy: existing.source
            };
            pathToPluginId[absPath] = manifest.id;
            // The bundled manifest can be scanned after the override that
            // shadows it, in which case the override was evaluated before the
            // id was known to be bundled. Settle it now. Only a declared
            // override can still be here: a bare collision was reclaimed above.
            if (sourceTag === "bundled") {
                existing.alwaysAvailable = existing.overridesBundled === true;
                // Through the gated path, not runStartupGate: this manifest is
                // exactly the fallback the override needs if it turns out to be
                // non-viable, so the scan order must not decide whether
                // demotion is available.
                if (existing.alwaysAvailable && !existing.loaded)
                    _gateThenSwap(manifest.id, null);
            }
        }
    }

    // `loaded` is a flag stored on the info record, but a package can have more
    // than one record over its lifetime: re-parsing a manifest builds a fresh
    // info object, and forceRescanPlugin does exactly that without tearing the
    // package down (so does the promotion at the end of _demoteToShipped). That
    // leaves availablePlugins holding the new record and loadedPlugins holding
    // the old one, and from there the two disagree permanently — unloadPlugin
    // clears the flag on whichever record loadedPlugins hands it, while the
    // record loadPlugin reads out of availablePlugins still claims `loaded`, so
    // loadPlugin early-returns true and installs nothing. The widget leaves the
    // bar with a PLUGIN_RELOAD_SUCCESS and no error anywhere. (VGS-75)
    //
    // Precedence is by id, but *identity* is by path: only a record for the same
    // manifest path may take the loaded registration over, because the installed
    // components belong to the package at that path, not to the id.
    function _relinkLoadedRecord(pluginId, info, absPath) {
        const current = loadedPlugins[pluginId];
        if (!current || current === info)
            return;
        if (current.manifestPath !== absPath) {
            // A different package's components are installed under this id.
            // This record starts from "not loaded" and takes it over through
            // the ordinary load path rather than inheriting a claim on them.
            info.loaded = false;
            return;
        }
        info.loaded = true;
        const relinked = Object.assign({}, loadedPlugins);
        relinked[pluginId] = info;
        loadedPlugins = relinked;
    }

    // Every manifest path currently known for an id. Used to name both sides of
    // a collision in a report; an id-level failure that does not say which
    // packages were competing is not actionable.
    function _knownPathsFor(pluginId) {
        const paths = [];
        for (const path in knownManifests) {
            if (pathToPluginId[path] === pluginId)
                paths.push(path);
        }
        return paths;
    }

    // A VGS product id that ends a resync with no package owning it means every
    // surface it backs is simply gone. Until VGS-75 that happened without a
    // single log line — the failure mode this whole path exists to make loud.
    //
    // Only when packages claiming the id are still on disk: that is a collision
    // that resolved to nothing, which is a bug. An id with no candidates left is
    // an ordinary uninstall — the bundled directory going away with a checkout
    // switch, say — and shouting about it would be noise, not a signal.
    function _reportIdLeftEmpty(pluginId) {
        const candidates = _knownPathsFor(pluginId);
        if (!candidates.length)
            return;
        log.error("no package owns bundled VGS plugin id, nothing is loaded:", pluginId, "candidates:", candidates.join(", "));
        ToastService.showError(I18n.tr("Plugin unavailable: %1").arg(pluginId), I18n.tr("No package could be loaded for this VGS module. Check Settings > Plugins."), "", "plugin-empty-" + pluginId);
    }

    // BEGIN OVERRIDE POLICY
    // Who owns a plugin id, and whether owning it grants always-available.
    // Pure: no QML API, no service calls, no side effects — the caller applies
    // the verdict. scripts/test-bundled-override.js extracts this block
    // verbatim and exercises the shipped source rather than a re-implementation
    // of it. Keep it free of anything node cannot evaluate.

    // A user or system package replaces a shipped VGS module only when its
    // manifest says so: `"overrides": "<bundled-id>"` (or a list, or `true` for
    // "whatever id I declare"). Reusing a shipped id without that is treated as
    // an accident — the trust decision is the manifest's, not the loader's
    // inference from a name match. (VGS-26)
    function _declaresBundledOverride(manifest, pluginId) {
        const claim = manifest.overrides;
        if (claim === true)
            return true;
        if (typeof claim === "string")
            return claim === pluginId;
        if (Array.isArray(claim))
            return claim.indexOf(pluginId) !== -1;
        return false;
    }

    // Does the incoming record take an id over from a package that is running
    // under it right now — i.e. must the swap tear the old one down before
    // installing the new one?
    //
    // Identity is by manifest path, never by source. Judging it by source was
    // survivable only while equal-priority packages could not displace each
    // other; the path tie-break made two user packages a real takeover, and a
    // takeover the loader does not see is one it does not unload. The old
    // package then stays in loadedPlugins with its components installed while
    // availablePlugins points at the new record — the exact identity desync
    // VGS-75 exists to remove, re-entered through the door the tie-break
    // opened. Two packages in one directory are still two packages. (VGS-75)
    function _displacesLoadedPackage(existing, incomingPath) {
        if (!existing || existing.loaded !== true)
            return false;
        return existing.manifestPath !== incomingPath;
    }

    // action:
    //   "block"   — inert; the shipped package keeps the id (bare collision)
    //   "reclaim" — the shipped package takes its id back from a bare collision
    //   "replace" — this package becomes the owner
    //   "shadow"  — a higher-priority package keeps the id
    function _bundledOverrideDecision(input) {
        const sourceTag = input.sourceTag;
        const bundledId = input.bundledId === true;
        const existing = input.existing || null;
        // Not gated on `bundledId`: the bundled directory may not have been
        // scanned yet, and a package that declares an override means it whether
        // or not this process has met the package it overrides.
        const overridesBundled = sourceTag !== "bundled" && _declaresBundledOverride(input.manifest, input.pluginId);
        // Always-available means "auto-enabled, and disablePlugin refuses it".
        // A declared override inherits it, because an override that owns the id
        // and never loads is the hole VGS-13 closed. A bare collision does not,
        // because it does not get to own the id at all.
        const alwaysAvailable = bundledId && (sourceTag === "bundled" || overridesBundled);
        const enabled = input.isPureDesktop === true || alwaysAvailable || input.userEnabled === true;

        if (bundledId && sourceTag !== "bundled" && !overridesBundled)
            return {
                "action": "block",
                "overridesBundled": overridesBundled,
                "alwaysAvailable": false,
                "enabled": false
            };

        // The shipped package outranks a bare collision that got there first
        // (the bundled directory can be scanned second), so it takes its id
        // back rather than staying shadowed by an accident.
        const reclaims = sourceTag === "bundled" && !!existing && existing.source !== "bundled" && existing.overridesBundled !== true;
        // Equal priority — two user packages claiming one id — used to resolve
        // on `>=`, i.e. whichever manifest read finished last became the owner.
        // FileView completion order is not something the loader controls, so
        // that made ownership genuinely nondeterministic: the same two packages
        // could swap owner across rescans of the same disk state. The tie-break
        // is the manifest path, which every read knows before it starts, so the
        // winner is the same whatever order the reads settle in. `<=` rather
        // than `<` because re-parsing the current owner's own path (a rescan,
        // or a manifest edited in place) must still replace its own record.
        const samePath = String(input.incomingPath) === String(input.existingPath);
        const winsTie = input.incomingPriority === input.existingPriority && (samePath || String(input.incomingPath) < String(input.existingPath));
        let action = "shadow";
        if (reclaims)
            action = "reclaim";
        else if (!existing || input.incomingPriority > input.existingPriority || winsTie)
            action = "replace";
        return {
            "action": action,
            "overridesBundled": overridesBundled,
            "alwaysAvailable": alwaysAvailable,
            "enabled": enabled
        };
    }
    // END OVERRIDE POLICY

    function _reportBundledCollision(pluginId, sourceTag) {
        const key = pluginId + ":" + sourceTag;
        if (_reportedCollisions[key])
            return;
        const next = Object.assign({}, _reportedCollisions);
        next[key] = true;
        _reportedCollisions = next;
        log.warn("plugin id collides with a bundled VGS module and does not declare an override:", pluginId, "source:", sourceTag);
        ToastService.showWarning(I18n.tr("Plugin id already used by VGS: %1").arg(pluginId), I18n.tr("The bundled module keeps this id. Add \"overrides\": \"%1\" to the plugin's plugin.json if replacing it was the intent.").arg(pluginId), "", "plugin-collision-" + pluginId);
    }

    // Is a shipped manifest for this id still on disk? That, not "something is
    // currently loaded", is what decides whether an override has anywhere to be
    // demoted to — the two differ in exactly the scan order VGS-13 verified,
    // where the override is parsed before the package it overrides.
    function _hasShippedManifest(pluginId) {
        for (const path in knownManifests) {
            const meta = knownManifests[path];
            if (meta && !meta.bad && meta.source === "bundled" && pathToPluginId[path] === pluginId)
                return true;
        }
        return false;
    }

    // Load a package that is taking an id over from another package: gate it
    // completely — compatibility, startupCheck, and component compilation —
    // before anything is torn down. Any failure hands the id back to the
    // shipped package rather than leaving it, and whatever product surface it
    // backs, with nothing loaded. `displaced` is the package still loaded under
    // this id, if any. (VGS-24)
    function _gateThenSwap(pluginId, displaced) {
        const incoming = availablePlugins[pluginId];
        if (!incoming) {
            runStartupGate(pluginId);
            return;
        }
        // Only the shipped package can be the fallback, and only for a package
        // that is not itself the shipped one.
        const canDemote = incoming.source !== "bundled" && _hasShippedManifest(pluginId);
        const giveUp = (reason, err) => {
            if (canDemote) {
                // `err` is deliberately NOT recorded as a load error here, and
                // this is not the reason going missing. `pluginLoadErrors` is
                // keyed by plugin ID, and after a demotion the ID belongs to
                // the SHIPPED package that took it back — recording the
                // refusal against it would attribute the failure to the
                // package that is now loaded and working.
                //
                // The durable record is on the manifest instead:
                // `_demoteToShipped` marks `knownManifests[path].demoted`, and
                // that entry already carries `requiresShell`, so
                // `requirementBlockReason` reconstructs the refusal from state
                // that outlives the toast and belongs to the right package.
                _demoteToShipped(pluginId, incoming, reason);
                return;
            }
            // Nothing to fall back to: report exactly as an ordinary failed
            // startup does, and leave whatever is still loaded alone.
            if (err) {
                _setLoadError(pluginId, err);
                const title = I18n.tr("%1 Startup Failed").arg(incoming.name || pluginId);
                ToastService.showError(title, err.details ? (err.title + "\n\n" + err.details) : err.title, "", "plugin-startup-" + pluginId);
            } else {
                ToastService.showError(I18n.tr("Plugin failed to load: %1").arg(incoming.name || pluginId), reason, "", "plugin-startup-" + pluginId);
            }
            pluginLoadFailed(pluginId, err ? err.title : reason);
        };

        // Records WHY this package is about to be refused, on the manifest it
        // was refused for. Every consumer of that fact then reads a recorded
        // cause instead of re-deriving one, which is what four separate review
        // findings were circling: `demoted` alone says a package lost its id,
        // not what took it away.
        //
        // Set BEFORE giveUp, so it covers the branch that demotes to a shipped
        // package AND the branch that cannot (no shipped manifest to fall back
        // to) — the second reported nothing outside `pluginLoadErrors` before.
        //
        // It lives on the knownManifests entry, which `loadPluginManifestFile`
        // rebuilds from scratch on every read, so the mark clears itself the
        // moment the manifest is re-read and judged again.
        const markRequirementRefusal = () => {
            const path = incoming.manifestPath;
            if (path && knownManifests[path])
                knownManifests[path].refusedOnRequirement = incoming.requires_shell;
        };

        const requires = incoming.requires_shell;
        // Only once the shell version is actually known: it is detected by an
        // async Process, and an unresolved version parses as 0.0.0, which would
        // fail every `>=` requirement during the first scan. An override that
        // slips through that window is judged by the ShellVersionService
        // Connections below, once the version lands.
        if (requires && ShellVersionService.semverVersion && !checkPluginCompatibility(requires)) {
            // Recorded, not just toasted. A toast is gone in seconds and
            // `plugin-scan status` reported an empty reason for this refusal,
            // so the one enforced constraint VGS has left no trace anywhere a
            // user could look afterwards. (VGS-89)
            const reason = I18n.tr("It requires VGS %1.").arg(requires);
            markRequirementRefusal();
            giveUp(reason, {
                title: reason,
                details: I18n.tr("This shell is VGS %1.").arg(ShellVersionService.semverVersion)
            });
            return;
        }
        _runStartupCheck(pluginId, err => {
            // A rescan can reassign the id while an async startupCheck is
            // pending. The gate that just passed belongs to `incoming`, so it
            // says nothing about whoever owns the id now.
            if (availablePlugins[pluginId] !== incoming)
                return;
            if (err) {
                giveUp(err.title, err);
                return;
            }
            // Compile before tearing anything down. loadPlugin installs its
            // components as it goes, so a component that fails halfway through
            // it would take the shipped surface with it; Qt caches compiled
            // components by URL, so the compile inside loadPlugin is a lookup.
            if (!_componentsCompile(pluginId)) {
                giveUp(I18n.tr("The plugin's components failed to load."), null);
                return;
            }
            _clearLoadError(pluginId);
            if (displaced)
                unloadPlugin(pluginId);
            if (loadPlugin(pluginId))
                return;
            giveUp(I18n.tr("The plugin's components failed to load."), null);
        });
    }

    // Dry-run the component compilation loadPlugin would do, without
    // installing anything. Instantiation failures (a launcher surface whose
    // object cannot be created) still surface from loadPlugin itself.
    function _componentsCompile(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (!plugin)
            return false;
        const componentPaths = plugin.componentPaths || {};
        for (const surface in componentPaths) {
            const comp = Qt.createComponent("file://" + componentPaths[surface], Component.PreferSynchronous);
            if (comp.status === Component.Error) {
                log.error("component error", pluginId, surface, comp.errorString());
                return false;
            }
        }
        return true;
    }

    // A shipped manifest's requires_shell is never *enforced*, and must not be:
    // a bundled package is always-available by construction, and refusing to
    // load one would take the product surface it backs offline (the app
    // launcher has no fallback since VGS-13), which is strictly worse than an
    // unmet declaration. That is why an impossible one stayed invisible — every
    // bundled manifest declared `>=1.0.0` against a 0.1.0 shell and nothing
    // judged it. It is not harmless: an override is normally a copy of the
    // shipped manifest, so it inherits the constraint and _gateThenSwap demotes
    // it, which made overriding any bundled plugin impossible. Judge it where it
    // is written rather than only where it is copied. scripts/test-bundled-override.js
    // turns the same comparison into a build-time failure. (VGS-76)
    function _auditBundledRequirement(pluginId, requires) {
        if (!requires || !ShellVersionService.semverVersion)
            return;
        if (checkPluginCompatibility(requires))
            return;
        log.error("bundled plugin declares a shell requirement this shell does not meet:", pluginId, requires, "shell:", ShellVersionService.semverVersion, "- loaded anyway, but it would demote any override copied from it");
    }

    // Shell version detection is asynchronous, so an override can take a
    // bundled id before its requires_shell can be judged. Once the version
    // lands, judge it: an override that is now known to be incompatible hands
    // the id back. Only overrides — a shipped package has nothing to demote to,
    // and refusing to load it would take the product surface down, which is the
    // outcome this whole path exists to prevent.
    Connections {
        target: ShellVersionService

        function onSemverVersionChanged() {
            if (!ShellVersionService.semverVersion)
                return;
            // Bundled manifests are parsed before the version lands too, so
            // this is where an impossible shipped requirement first becomes
            // judgeable. Audited, never enforced — see
            // _auditBundledRequirement. (VGS-76)
            //
            // Over knownManifests rather than availablePlugins: a shipped
            // manifest that is shadowed by an override owns no record in
            // availablePlugins, so auditing only the winners silently skipped
            // exactly the bundled/override pairing this audit exists to
            // diagnose — the one where the impossible requirement was copied
            // into the override and demoted it.
            for (const manifestPath in root.knownManifests) {
                const meta = root.knownManifests[manifestPath];
                if (!meta || meta.bad || meta.source !== "bundled")
                    continue;
                root._auditBundledRequirement(root.pathToPluginId[manifestPath] || manifestPath, meta.requiresShell);
            }
            for (const pluginId in root.availablePlugins) {
                const plugin = root.availablePlugins[pluginId];
                if (!plugin || plugin.source === "bundled")
                    continue;
                if (plugin.overridesBundled !== true || !plugin.requires_shell)
                    continue;
                if (root.checkPluginCompatibility(plugin.requires_shell))
                    continue;
                if (!root._hasShippedManifest(pluginId))
                    continue;
                root._demoteToShipped(pluginId, plugin, I18n.tr("It requires VGS %1.").arg(plugin.requires_shell));
            }
        }
    }

    // Hand the id back to the package the override displaced. The shipped
    // manifest is still in knownManifests (shadowed), so re-parsing it makes it
    // the owner again; if it was never unloaded it simply keeps running.
    function _demoteToShipped(pluginId, incoming, reason) {
        const overridePath = incoming ? incoming.manifestPath : "";
        if (overridePath && knownManifests[overridePath])
            knownManifests[overridePath].demoted = true;
        // By identity: an override demoted after it loaded (a requires_shell
        // recheck) has to go, but in the gate-failure case loadedPlugins still
        // holds the shipped package, which is the thing being restored.
        if (incoming && loadedPlugins[pluginId] === incoming)
            unloadPlugin(pluginId);
        if (availablePlugins[pluginId] === incoming) {
            const newMap = Object.assign({}, availablePlugins);
            delete newMap[pluginId];
            availablePlugins = newMap;
        }
        _updateAvailablePluginsList();
        pluginListUpdated();
        const name = incoming ? (incoming.name || pluginId) : pluginId;
        // Reported only once the promotion has settled. Starting a manifest
        // read is not a restored plugin: the promoted candidate can fail to
        // parse, be invalid, be blocked, or fail its own gate, and saying "the
        // version bundled with VGS is still in use" at that point tells the
        // user everything is fine while nothing owns or loads the id — the same
        // silent failure this path exists to remove. (VGS-75)
        promoteShadowedPlugin(pluginId, function (ok) {
            if (!ok) {
                // Nothing took the id back. The demotion is the moment a
                // collision can end with no plugin loaded at all, so it is
                // reported as the failure it is, naming both candidates.
                root.log.error("override demotion left the id with nothing loaded:", pluginId, "override:", overridePath || "(unknown)", "candidates:", root._knownPathsFor(pluginId).join(", ") || "(none)", reason);
                ToastService.showError(I18n.tr("Plugin unavailable: %1").arg(name), I18n.tr("%1 No bundled version could be restored, so nothing is loaded for \"%2\".").arg(reason).arg(pluginId), "", "plugin-demoted-" + pluginId);
                return;
            }
            // Which package took the id is a fact to be read, not assumed:
            // promoteShadowedPlugin picks the highest-priority eligible
            // candidate, and with several overrides claiming one id that can
            // be another user package rather than the shipped one. Naming the
            // bundled version regardless would hand the user, and anyone
            // reading the log, the wrong identity for what is running.
            const restored = root.loadedPlugins[pluginId] || root.availablePlugins[pluginId] || null;
            const restoredName = restored ? (restored.name || pluginId) : pluginId;
            const restoredPath = restored ? (restored.manifestPath || "(unknown)") : "(unknown)";
            root.log.warn("override failed to take over bundled id, demoting:", pluginId, reason, "restored:", restoredName, "source:", restored ? restored.source : "(unknown)", restoredPath);
            const body = (restored && restored.source === "bundled") ? I18n.tr("%1 could not start, so the version bundled with VGS is still in use.").arg(reason) : I18n.tr("%1 could not start, so \"%2\" is in use for this plugin instead.").arg(reason).arg(restoredName);
            ToastService.showError(I18n.tr("Plugin override failed: %1").arg(name), body, "", "plugin-demoted-" + pluginId);
        }, overridePath);
    }

    // A bundled id must not outlive the bundled directory: a shipped package
    // that goes away (a partial upgrade, a dev checkout switch) would otherwise
    // keep a same-id user package auto-enabled and undisableable until the
    // shell restarts. Called from resyncAll after the removed manifests are
    // gone from knownManifests, which is what makes the "any left?" scan
    // meaningful. (VGS-39)
    function _refreshBundledId(pluginId) {
        if (_bundledPluginIds[pluginId] !== true || _hasShippedManifest(pluginId))
            return;
        const next = Object.assign({}, _bundledPluginIds);
        delete next[pluginId];
        _bundledPluginIds = next;
        // Nothing shipped owns the id any more, so packages held back purely
        // for colliding with it are ordinary plugins again — including one that
        // was demoted, whose only reason for being refused was the shipped
        // competitor that has now gone. It gets promoted, runs its own startup
        // gate like any plugin, and fails visibly if it is still broken.
        for (const path in knownManifests) {
            const meta = knownManifests[path];
            if (!meta || pathToPluginId[path] !== pluginId)
                continue;
            delete meta.blocked;
            delete meta.demoted;
        }
        for (const key in _reportedCollisions) {
            if (key.indexOf(pluginId + ":") === 0) {
                const cleared = Object.assign({}, _reportedCollisions);
                delete cleared[key];
                _reportedCollisions = cleared;
            }
        }
    }

    // True when the id is a VGS product module the shell guarantees: bundled,
    // or a user package that declared itself the override of one. Those are
    // auto-enabled and disablePlugin refuses them, so UI must not offer a
    // disable affordance for them. (VGS-39)
    function isAlwaysAvailablePlugin(pluginId) {
        if (_bundledPluginIds[pluginId] !== true)
            return false;
        const plugin = availablePlugins[pluginId];
        return !plugin || plugin.alwaysAvailable === true;
    }

    function unregisterPluginByPath(absPath, pluginId) {
        const current = availablePlugins[pluginId];
        if (current && current.manifestPath === absPath) {
            if (current.loaded)
                unloadPlugin(pluginId);
            const newMap = Object.assign({}, availablePlugins);
            delete newMap[pluginId];
            availablePlugins = newMap;
        }
    }

    function loadPlugin(pluginId, bustCache) {
        const plugin = availablePlugins[pluginId];
        if (!plugin) {
            log.error("Plugin not found:", pluginId);
            pluginLoadFailed(pluginId, "Plugin not found");
            return false;
        }

        if (plugin.loaded) {
            if (loadedPlugins[pluginId] === plugin)
                return true;
            // The record claims loaded but it is not the record registered under
            // the id, so returning true would report a success that installs no
            // components — exactly the silent disappearance in VGS-75.
            // _relinkLoadedRecord keeps the two in step; if anything else ever
            // desynchronises them, say so and do the load for real rather than
            // no-op behind a success.
            log.error("plugin record claims loaded but is not the registered one, loading for real:", pluginId, plugin.manifestPath || "(no path)");
            plugin.loaded = false;
        }

        const componentPaths = plugin.componentPaths || {};
        const surfaces = Object.keys(componentPaths);
        if (surfaces.length === 0) {
            log.error("Plugin has no component surfaces:", pluginId);
            pluginLoadFailed(pluginId, "No component surfaces");
            return false;
        }

        const newWidgets = Object.assign({}, pluginWidgetComponents);
        const newDesktop = Object.assign({}, pluginDesktopComponents);
        const newDaemons = Object.assign({}, pluginDaemonComponents);
        const newLaunchers = Object.assign({}, pluginLauncherComponents);
        const newInstances = Object.assign({}, pluginInstances);

        const prevInstance = newInstances[pluginId];
        if (prevInstance) {
            prevInstance.destroy();
            delete newInstances[pluginId];
        }

        try {
            for (const surface of surfaces) {
                let url = "file://" + componentPaths[surface];
                if (bustCache)
                    url += "?t=" + Date.now();
                const comp = Qt.createComponent(url, Component.PreferSynchronous);
                if (comp.status === Component.Error) {
                    log.error("component error", pluginId, surface, comp.errorString());
                    pluginLoadFailed(pluginId, comp.errorString());
                    return false;
                }

                switch (surface) {
                case "daemon":
                    newDaemons[pluginId] = comp;
                    break;
                case "desktop":
                    newDesktop[pluginId] = comp;
                    break;
                case "launcher": {
                    const instance = comp.createObject(root, {
                        "pluginService": root
                    });
                    if (!instance) {
                        log.error("failed to instantiate launcher surface:", pluginId, comp.errorString());
                        pluginLoadFailed(pluginId, comp.errorString());
                        return false;
                    }
                    newInstances[pluginId] = instance;
                    newLaunchers[pluginId] = comp;
                    break;
                }
                default:
                    newWidgets[pluginId] = comp;
                    break;
                }
            }

            pluginWidgetComponents = newWidgets;
            pluginDesktopComponents = newDesktop;
            pluginDaemonComponents = newDaemons;
            pluginLauncherComponents = newLaunchers;
            pluginInstances = newInstances;

            plugin.loaded = true;
            const newLoaded = Object.assign({}, loadedPlugins);
            newLoaded[pluginId] = plugin;
            loadedPlugins = newLoaded;

            pluginLoaded(pluginId);
            return true;
        } catch (e) {
            log.error("Error loading plugin:", pluginId, e.message);
            pluginLoadFailed(pluginId, e.message);
            return false;
        }
    }

    function unloadPlugin(pluginId) {
        const plugin = loadedPlugins[pluginId];
        if (!plugin) {
            log.warn("Plugin not loaded:", pluginId);
            return false;
        }

        try {
            const instance = pluginInstances[pluginId];
            if (instance) {
                instance.destroy();
                const newInstances = Object.assign({}, pluginInstances);
                delete newInstances[pluginId];
                pluginInstances = newInstances;
            }

            if (pluginDaemonComponents[pluginId]) {
                const newDaemons = Object.assign({}, pluginDaemonComponents);
                delete newDaemons[pluginId];
                pluginDaemonComponents = newDaemons;
            }
            if (pluginLauncherComponents[pluginId]) {
                const newLaunchers = Object.assign({}, pluginLauncherComponents);
                delete newLaunchers[pluginId];
                pluginLauncherComponents = newLaunchers;
            }
            if (pluginDesktopComponents[pluginId]) {
                const newDesktop = Object.assign({}, pluginDesktopComponents);
                delete newDesktop[pluginId];
                pluginDesktopComponents = newDesktop;
            }
            if (pluginWidgetComponents[pluginId]) {
                const newComponents = Object.assign({}, pluginWidgetComponents);
                delete newComponents[pluginId];
                pluginWidgetComponents = newComponents;
            }

            plugin.loaded = false;
            // The record availablePlugins holds can be a different object for
            // the same package after a re-parse. Clearing only the loadedPlugins
            // one leaves the other claiming `loaded` forever. (VGS-75)
            const current = availablePlugins[pluginId];
            if (current && current !== plugin)
                current.loaded = false;
            const newLoaded = Object.assign({}, loadedPlugins);
            delete newLoaded[pluginId];
            loadedPlugins = newLoaded;

            _cleanupPluginStateWriter(pluginId);
            pluginUnloaded(pluginId);
            return true;
        } catch (error) {
            log.error("Error unloading plugin:", pluginId, "Error:", error.message);
            return false;
        }
    }

    function getWidgetComponents() {
        return pluginWidgetComponents;
    }

    function getDaemonComponents() {
        return pluginDaemonComponents;
    }

    function getDesktopComponents() {
        return pluginDesktopComponents;
    }

    function getAvailablePlugins() {
        return availablePluginsList;
    }

    function _updateAvailablePluginsList() {
        const result = [];
        for (const key in availablePlugins) {
            result.push(availablePlugins[key]);
        }
        availablePluginsList = result;
    }

    function getPluginVariants(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (!plugin) {
            return [];
        }
        const variants = SettingsData.getPluginSetting(pluginId, "variants", []);
        return variants;
    }

    function getAllPluginVariants() {
        const result = [];
        for (const pluginId in availablePlugins) {
            const plugin = availablePlugins[pluginId];
            const hasWidgetSurface = plugin.surfaces ? plugin.surfaces.includes("widget") : (plugin.type === "widget");
            if (!hasWidgetSurface) {
                continue;
            }
            const variants = getPluginVariants(pluginId);
            if (variants.length === 0) {
                result.push({
                    pluginId: pluginId,
                    variantId: null,
                    fullId: pluginId,
                    name: plugin.name,
                    icon: plugin.icon || "extension",
                    description: plugin.description || "Plugin widget",
                    loaded: plugin.loaded,
                    source: plugin.source || "user",
                    settingsPath: plugin.settingsPath || ""
                });
            } else {
                for (let i = 0; i < variants.length; i++) {
                    const variant = variants[i];
                    result.push({
                        pluginId: pluginId,
                        variantId: variant.id,
                        fullId: pluginId + ":" + variant.id,
                        name: plugin.name + " - " + variant.name,
                        icon: variant.icon || plugin.icon || "extension",
                        description: variant.description || plugin.description || "Plugin widget variant",
                        loaded: plugin.loaded,
                        source: plugin.source || "user",
                        settingsPath: plugin.settingsPath || ""
                    });
                }
            }
        }
        return result;
    }

    function createPluginVariant(pluginId, variantName, variantConfig) {
        const variants = getPluginVariants(pluginId);
        const variantId = "variant_" + Date.now();
        const newVariant = Object.assign({}, variantConfig, {
            id: variantId,
            name: variantName
        });
        variants.push(newVariant);
        SettingsData.setPluginSetting(pluginId, "variants", variants);
        pluginDataChanged(pluginId);
        return variantId;
    }

    function removePluginVariant(pluginId, variantId) {
        const variants = getPluginVariants(pluginId);
        const newVariants = variants.filter(function (v) {
            return v.id !== variantId;
        });
        SettingsData.setPluginSetting(pluginId, "variants", newVariants);

        const fullId = pluginId + ":" + variantId;
        removeWidgetFromBar(fullId);

        pluginDataChanged(pluginId);
    }

    function removeWidgetFromBar(widgetId) {
        function filterWidget(widget) {
            const id = typeof widget === "string" ? widget : widget.id;
            return id !== widgetId;
        }

        const defaultBar = SettingsData.barConfigs[0] || SettingsData.getBarConfig("default");
        if (!defaultBar)
            return;
        const leftWidgets = defaultBar.leftWidgets || [];
        const centerWidgets = defaultBar.centerWidgets || [];
        const rightWidgets = defaultBar.rightWidgets || [];

        const newLeft = leftWidgets.filter(filterWidget);
        const newCenter = centerWidgets.filter(filterWidget);
        const newRight = rightWidgets.filter(filterWidget);

        if (newLeft.length !== leftWidgets.length) {
            SettingsData.setBarLeftWidgets(newLeft);
        }
        if (newCenter.length !== centerWidgets.length) {
            SettingsData.setBarCenterWidgets(newCenter);
        }
        if (newRight.length !== rightWidgets.length) {
            SettingsData.setBarRightWidgets(newRight);
        }
    }

    function updatePluginVariant(pluginId, variantId, variantConfig) {
        const variants = getPluginVariants(pluginId);
        for (let i = 0; i < variants.length; i++) {
            if (variants[i].id === variantId) {
                variants[i] = Object.assign({}, variants[i], variantConfig);
                break;
            }
        }
        SettingsData.setPluginSetting(pluginId, "variants", variants);
        pluginDataChanged(pluginId);
    }

    function getPluginVariantData(pluginId, variantId) {
        const variants = getPluginVariants(pluginId);
        for (let i = 0; i < variants.length; i++) {
            if (variants[i].id === variantId) {
                return variants[i];
            }
        }
        return null;
    }

    function getLoadedPlugins() {
        const result = [];
        for (const key in loadedPlugins) {
            result.push(loadedPlugins[key]);
        }
        return result;
    }

    function isPluginLoaded(pluginId) {
        return loadedPlugins[pluginId] !== undefined;
    }

    function enablePlugin(pluginId, onResult) {
        SettingsData.setPluginSetting(pluginId, "enabled", true);
        return runStartupGate(pluginId, onResult);
    }

    function _setLoadError(pluginId, err) {
        const m = Object.assign({}, pluginLoadErrors);
        m[pluginId] = err;
        pluginLoadErrors = m;
    }

    function _clearLoadError(pluginId) {
        if (!pluginLoadErrors[pluginId])
            return;
        const m = Object.assign({}, pluginLoadErrors);
        delete m[pluginId];
        pluginLoadErrors = m;
    }

    function _normalizeStartupError(result) {
        if (!result)
            return null;
        if (typeof result === "string")
            return {
                "title": result,
                "details": ""
            };
        return {
            "title": result.title || I18n.tr("Plugin dependency missing"),
            "details": result.details || ""
        };
    }

    function _makeStartupCheckObject(pluginId, plugin) {
        const comp = Qt.createComponent("file://" + plugin.startupCheckPath, Component.PreferSynchronous);
        if (comp.status === Component.Error) {
            log.error("startupCheck component error", pluginId, comp.errorString());
            return null;
        }
        return comp.createObject(root);
    }

    // Evaluate a package's startup gate and report the outcome — normalized
    // error object, or null for "viable" — without loading anything. Split out
    // so a swap can be gated before the package it would replace is torn down.
    function _runStartupCheck(pluginId, onChecked) {
        const plugin = availablePlugins[pluginId];
        if (!plugin) {
            onChecked({
                "title": I18n.tr("Plugin not found"),
                "details": ""
            });
            return;
        }
        if (!plugin.startupCheckPath) {
            onChecked(null);
            return;
        }

        const probe = _makeStartupCheckObject(pluginId, plugin);
        const finish = result => {
            if (probe)
                probe.destroy();
            onChecked(_normalizeStartupError(result));
        };

        const check = probe ? probe.check : null;
        if (typeof check !== "function") {
            finish(null);
            return;
        }
        if (check.length >= 1) {
            try {
                check(finish);
            } catch (e) {
                log.warn("startupCheck threw for", pluginId, e.message);
                finish(null);
            }
            return;
        }
        let r = null;
        try {
            r = check();
        } catch (e) {
            log.warn("startupCheck threw for", pluginId, e.message);
            r = null;
        }
        finish(r);
    }

    function runStartupGate(pluginId, onResult) {
        const plugin = availablePlugins[pluginId];
        if (!plugin) {
            if (onResult)
                onResult(false);
            return false;
        }

        // A gate with no startupCheck, or a synchronous one, settles before
        // this returns. Report the real outcome to callers that read the
        // return value (the plugin IPC does); an async gate can only answer
        // "started", as before.
        let settled = null;
        _runStartupCheck(pluginId, err => {
            if (err) {
                _setLoadError(pluginId, err);
                const title = I18n.tr("%1 Startup Failed").arg(plugin.name || pluginId);
                const body = err.details ? (err.title + "\n\n" + err.details) : err.title;
                ToastService.showError(title, body, "", "plugin-startup-" + pluginId);
                pluginLoadFailed(pluginId, err.title);
                settled = false;
                if (onResult)
                    onResult(false);
                return;
            }
            _clearLoadError(pluginId);
            const ok = loadPlugin(pluginId);
            settled = ok;
            if (onResult)
                onResult(ok);
        });
        return settled === null ? true : settled;
    }

    function disablePlugin(pluginId) {
        // Keyed on the id and the owner's claim on it, not on the winning
        // source: a package that declared itself the override of a bundled id
        // inherits the always-available invariant, so disabling it would take a
        // VGS product surface offline through the plugin UI. Callers must not
        // offer the affordance in the first place — see isAlwaysAvailablePlugin.
        if (isAlwaysAvailablePlugin(pluginId)) {
            log.warn("Bundled VGS module cannot be disabled as a third-party plugin:", pluginId);
            return false;
        }
        SettingsData.setPluginSetting(pluginId, "enabled", false);
        return unloadPlugin(pluginId);
    }

    function reloadPlugin(pluginId) {
        if (isPluginLoaded(pluginId))
            unloadPlugin(pluginId);
        return loadPlugin(pluginId, true);
    }

    // Register a daemon plugin item owned by the shell's daemon Instantiator.
    function registerDaemonInstance(pluginId, instance) {
        if (!instance)
            return;
        const next = Object.assign({}, daemonInstances);
        next[pluginId] = instance;
        daemonInstances = next;
    }

    // Drop a registration, by identity. A reload destroys the old delegate and
    // builds a new one, and QML does not order those two events; comparing
    // identity stops a late teardown from wiping the live replacement.
    function unregisterDaemonInstance(pluginId, instance) {
        if (!instance || daemonInstances[pluginId] !== instance)
            return;
        const next = Object.assign({}, daemonInstances);
        delete next[pluginId];
        daemonInstances = next;
    }

    // The live object for a plugin, whichever surface owns it. Prefer the
    // shell-owned daemon item so callers never race a second instance.
    function getPluginInstance(pluginId) {
        return daemonInstances[pluginId] || pluginInstances[pluginId] || null;
    }

    function togglePlugin(pluginId) {
        // Daemon components are constructed by the shell's daemon Instantiator
        // (VGS.qml), which owns their lifetime — constructing one here would
        // duplicate every IpcHandler the plugin declares. That Instantiator is
        // asynchronous, so "component loaded but instance not registered yet"
        // is a normal transient state; report it as unavailable and let the
        // caller decide, rather than racing it with a second object.
        const instance = getPluginInstance(pluginId);
        if (instance && typeof instance.toggle === "function") {
            instance.toggle();
            return true;
        }
        return false;
    }

    // Single seam between core shell UI and the bundled launcher package. The
    // dock button, the bar widget and the changelog card all route through
    // here, so the plugin id is defined once and the unavailable-launcher
    // handling lives in one place. Since VGS-13 the shell ships no fallback
    // launcher, so a failure here has to be visible rather than a dead click.
    readonly property string appLauncherPluginId: "vgsMenu"

    // The open-state half of the same seam. Core shell code binds to this
    // rather than reaching for a `menuOpen` property on whatever object is
    // registered for the id, so the whole launcher contract — id, toggle,
    // open state — is declared in one place. Falls back to false, which is
    // the safe answer for callers that yield to the launcher when it opens.
    readonly property bool appLauncherOpen: getPluginInstance(appLauncherPluginId)?.menuOpen ?? false

    // What is queued is an absolute intent — "the launcher should be open" —
    // not a deferred toggle. A toggle is relative, and replaying a relative
    // operation against a state that moved while it waited is what makes a
    // queue like this fragile: two clicks during startup would either collapse
    // (losing one) or replay (opening and shutting the launcher in the user's
    // face), and a registration that arrives with the launcher ALREADY open
    // would be closed by the replay. Intent has no parity to lose. While no
    // instance is registered the launcher is closed by definition
    // (appLauncherOpen reads false), so every click in that window can only
    // mean "open it", however many arrive.
    property bool _appLauncherOpenPending: false

    function toggleAppLauncher() {
        if (togglePlugin(appLauncherPluginId)) {
            _appLauncherOpenPending = false;
            appLauncherRegistrationTimeout.stop();
            return true;
        }
        // The daemon Instantiator is asynchronous, so a click can land after
        // the component loads but before the instance registers. That is a
        // transient startup state, not a failure: record the intent and let
        // onDaemonInstancesChanged satisfy it, rather than crying wolf.
        if (pluginDaemonComponents[appLauncherPluginId] && !daemonInstances[appLauncherPluginId]) {
            // Deadline runs from the FIRST click. Restarting it per click
            // would let an impatient user postpone the error indefinitely.
            if (!_appLauncherOpenPending) {
                _appLauncherOpenPending = true;
                appLauncherRegistrationTimeout.restart();
            }
            return false;
        }
        _reportAppLauncherUnavailable();
        return false;
    }

    // Satisfies a queued intent. Prefers the explicit open() over toggle() so
    // an instance that registers already open is left alone.
    function _openAppLauncher() {
        const instance = getPluginInstance(appLauncherPluginId);
        if (!instance)
            return false;
        if (instance.menuOpen === true)
            return true;
        if (typeof instance.open === "function") {
            instance.open();
            return true;
        }
        if (typeof instance.toggle === "function") {
            instance.toggle();
            return true;
        }
        return false;
    }

    function _reportAppLauncherUnavailable() {
        _appLauncherOpenPending = false;
        // Three distinguishable failures wanting three different pieces of
        // advice. Pointing someone at Settings > Plugins when the plugin is
        // loaded and merely slow sends them where nothing is wrong.
        if (getPluginInstance(appLauncherPluginId)) {
            log.error("app launcher unavailable:", appLauncherPluginId, "registered an instance with no callable open()/toggle()");
            ToastService.showError(I18n.tr("App launcher unavailable"), I18n.tr("The %1 plugin registered without a launcher to open.").arg(appLauncherPluginId), "", "app-launcher-unavailable");
            return;
        }
        if (pluginDaemonComponents[appLauncherPluginId]) {
            log.error("app launcher unavailable:", appLauncherPluginId, "loaded but never registered an instance");
            ToastService.showError(I18n.tr("App launcher unavailable"), I18n.tr("The %1 launcher did not finish starting.").arg(appLauncherPluginId), "", "app-launcher-unavailable");
            return;
        }
        log.error("app launcher unavailable:", appLauncherPluginId, "is not loaded");
        ToastService.showError(I18n.tr("App launcher unavailable"), I18n.tr("The %1 plugin did not load.").arg(appLauncherPluginId), "", "app-launcher-unavailable", ({
            label: I18n.tr("Open Plugins settings"),
            settingsTab: "plugins"
        }));
    }

    onDaemonInstancesChanged: {
        if (!_appLauncherOpenPending || !daemonInstances[appLauncherPluginId])
            return;
        _appLauncherOpenPending = false;
        appLauncherRegistrationTimeout.stop();
        // A registration that cannot serve the intent is still a dead click,
        // and the timeout is stopped by now, so it can no longer report it.
        // Both failure paths end in the same reporter rather than two that
        // could disagree.
        if (!_openAppLauncher())
            _reportAppLauncherUnavailable();
    }

    // Bounds the queued intent above: if registration never arrives, the click
    // has to end in a visible error rather than nothing at all.
    Timer {
        id: appLauncherRegistrationTimeout
        interval: 2000
        repeat: false
        onTriggered: {
            if (root._appLauncherOpenPending)
                root._reportAppLauncherUnavailable();
        }
    }

    // Nothing else consumes this signal, so a component load error used to
    // reach only the log. Plugin surfaces back real product UI (the app
    // launcher has no fallback since VGS-13), so a failed load has to be
    // visible to the user.
    onPluginLoadFailed: (pluginId, error) => {
        // The startup-gate path records the error first and raises a richer
        // toast of its own; do not replace it with this generic one.
        if (pluginLoadErrors[pluginId])
            return;
        const plugin = availablePlugins[pluginId];
        ToastService.showError(I18n.tr("%1 failed to load").arg(plugin?.name || pluginId), error || "", "", "plugin-load-" + pluginId);
    }

    function savePluginData(pluginId, key, value) {
        SettingsData.setPluginSetting(pluginId, key, value);
        pluginDataChanged(pluginId);
        return true;
    }

    function loadPluginData(pluginId, key, defaultValue) {
        return SettingsData.getPluginSetting(pluginId, key, defaultValue);
    }

    function getPluginPath(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (!plugin)
            return "";
        return plugin.pluginDirectory || "";
    }

    function saveAllPluginSettings() {
        SettingsData.savePluginSettings();
    }

    function getPluginStatePath(pluginId) {
        return Paths.strip(Paths.state) + "/plugins/" + pluginId + "_state.json";
    }

    function loadPluginState(pluginId, key, defaultValue) {
        if (!_stateLoaded[pluginId])
            _loadStateFromDisk(pluginId);
        const state = _stateCache[pluginId];
        if (!state)
            return defaultValue;
        return state[key] !== undefined ? state[key] : defaultValue;
    }

    function savePluginState(pluginId, key, value) {
        if (!_stateLoaded[pluginId])
            _loadStateFromDisk(pluginId);
        if (!_stateCache[pluginId])
            _stateCache[pluginId] = {};
        _stateCache[pluginId][key] = value;
        _stateDirtyPlugins[pluginId] = true;
        _stateWriteTimer.restart();
        pluginStateChanged(pluginId);
    }

    function clearPluginState(pluginId) {
        _stateCache[pluginId] = {};
        _stateLoaded[pluginId] = true;
        _flushStateToDisk(pluginId);
        pluginStateChanged(pluginId);
    }

    function removePluginStateKey(pluginId, key) {
        if (!_stateCache[pluginId])
            return;
        delete _stateCache[pluginId][key];
        _stateDirtyPlugins[pluginId] = true;
        _stateWriteTimer.restart();
        pluginStateChanged(pluginId);
    }

    function _ensureStateDir() {
        if (_stateDirCreated)
            return;
        _stateDirCreated = true;
        Paths.mkdir(Paths.state + "/plugins");
    }

    function _loadStateFromDisk(pluginId) {
        _stateLoaded[pluginId] = true;
        _ensureStateDir();
        const path = getPluginStatePath(pluginId);
        try {
            const fv = stateLoadFvComp.createObject(root, {
                path: path
            });
            const raw = fv.text();
            if (raw && raw.trim()) {
                _stateCache[pluginId] = JSON.parse(raw);
            } else {
                _stateCache[pluginId] = {};
            }
            _stateWriters[pluginId] = fv;
        } catch (e) {
            _stateCache[pluginId] = {};
        }
    }

    function _flushStateToDisk(pluginId) {
        _ensureStateDir();
        const content = JSON.stringify(_stateCache[pluginId] || {}, null, 2);
        if (_stateWriters[pluginId]) {
            _stateWriters[pluginId].setText(content);
            return;
        }
        const path = getPluginStatePath(pluginId);
        try {
            const fv = stateSaveFvComp.createObject(root, {
                path: path
            });
            _stateWriters[pluginId] = fv;
            fv.loaded.connect(function () {
                fv.setText(content);
            });
            fv.loadFailed.connect(function () {
                fv.setText(content);
            });
        } catch (e) {
            log.warn("Failed to write state for", pluginId, e.message);
        }
    }

    Component {
        id: stateLoadFvComp
        FileView {
            blockLoading: true
            blockWrites: true
            atomicWrites: true
        }
    }

    Component {
        id: stateSaveFvComp
        FileView {
            blockWrites: true
            atomicWrites: true
        }
    }

    function _flushDirtyStates() {
        const dirty = _stateDirtyPlugins;
        _stateDirtyPlugins = {};
        for (const pluginId in dirty)
            _flushStateToDisk(pluginId);
    }

    function _cleanupPluginStateWriter(pluginId) {
        if (!_stateWriters[pluginId])
            return;
        _stateWriters[pluginId].destroy();
        delete _stateWriters[pluginId];
    }

    function scanPlugins() {
        const userUrl = Paths.toFileUrl(root.pluginDirectory);
        const bundledUrl = Paths.toFileUrl(root.bundledPluginDirectory);
        const systemUrl = Paths.toFileUrl(root.systemPluginDirectory);
        userWatcher.folder = "";
        userWatcher.folder = userUrl;
        bundledWatcher.folder = "";
        bundledWatcher.folder = bundledUrl;
        systemWatcher.folder = "";
        systemWatcher.folder = systemUrl;
        resyncDebounce.restart();
        checkPluginDirectoryExists();
    }

    // Re-evaluate a plugin from disk, by id, across every manifest that claims
    // that id — not just the path that happens to own it right now.
    //
    // resyncAll's consider() loads a path only when it is *unknown*, so a
    // package that lost the id once — blocked as a bare collision, or demoted
    // by its version gate — is never read again for the life of the process.
    // Rescanning the owner's path alone therefore could not change any outcome
    // an override was involved in: editing the override and rescanning produced
    // no log output and no change at all. Precedence has to be settled by id
    // after the manifests are (re)loaded, which is what re-parsing all of them
    // and letting _bundledOverrideDecision arbitrate does. Dropping the
    // knownManifests entries first is deliberate: it clears the blocked/demoted
    // flags, so a rescan is a genuinely fresh verdict rather than a replay of
    // the old one. (VGS-75)
    //
    // The manifest loads are asynchronous and may settle in any order, and the
    // policy arbitrates to the same owner whatever that order is: source
    // priority decides across sources, and manifest path breaks a tie within
    // one source (see _bundledOverrideDecision). The priority ordering below
    // is therefore not load-bearing — it only keeps the transient states during
    // a rescan closer to the final one.
    function forceRescanPlugin(pluginId) {
        const owner = availablePlugins[pluginId];
        const paths = _knownPathsFor(pluginId);
        if (owner && owner.manifestPath && paths.indexOf(owner.manifestPath) === -1)
            paths.push(owner.manifestPath);
        if (!paths.length)
            return false;

        const entries = paths.map(function (p) {
            const meta = knownManifests[p];
            let source = meta ? meta.source : "";
            if (!source && owner && owner.manifestPath === p)
                source = owner.source;
            return {
                path: p,
                source: source || "user"
            };
        });
        entries.sort(function (a, b) {
            return _sourcePriority(a.source) - _sourcePriority(b.source);
        });

        for (let i = 0; i < entries.length; i++)
            delete knownManifests[entries[i].path];
        if (owner) {
            const newMap = Object.assign({}, availablePlugins);
            delete newMap[pluginId];
            availablePlugins = newMap;
        }
        const stamp = Date.now();
        for (let i = 0; i < entries.length; i++)
            loadPluginManifestFile(entries[i].path, entries[i].source, stamp);
        return true;
    }

    function createPluginDirectory() {
        Quickshell.execDetached(["mkdir", "-p", pluginDirectory]);
        Qt.callLater(checkPluginDirectoryExists);
        return true;
    }

    function openPluginDirectory() {
        Qt.openUrlExternally(Paths.toFileUrl(pluginDirectory));
        return true;
    }

    // Launcher plugin helper functions
    function getLauncherPlugins() {
        const launchers = {};

        // Check plugins that have launcher components
        for (const pluginId in pluginLauncherComponents) {
            const plugin = availablePlugins[pluginId];
            if (plugin && plugin.loaded) {
                launchers[pluginId] = plugin;
            }
        }
        return launchers;
    }

    function getLauncherPlugin(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (plugin && plugin.loaded && pluginLauncherComponents[pluginId]) {
            return plugin;
        }
        return null;
    }

    function getPluginTrigger(pluginId) {
        const plugin = getLauncherPlugin(pluginId);
        if (plugin) {
            // Check if noTrigger is set (always active mode)
            const noTrigger = SettingsData.getPluginSetting(pluginId, "noTrigger", false);
            if (noTrigger) {
                return "";
            }
            // Otherwise load the custom trigger, defaulting to plugin manifest trigger
            const customTrigger = SettingsData.getPluginSetting(pluginId, "trigger", plugin.trigger || "!");
            return customTrigger;
        }
        return null;
    }

    function getAllPluginTriggers() {
        const triggers = {};
        const launchers = getLauncherPlugins();

        for (const pluginId in launchers) {
            const trigger = getPluginTrigger(pluginId);
            if (trigger && trigger.trim() !== "") {
                triggers[trigger] = pluginId;
            }
        }
        return triggers;
    }

    function getPluginsWithEmptyTrigger() {
        const plugins = [];
        const launchers = getLauncherPlugins();

        for (const pluginId in launchers) {
            const trigger = getPluginTrigger(pluginId);
            if (!trigger || trigger.trim() === "") {
                plugins.push(pluginId);
            }
        }
        return plugins;
    }

    function getPluginViewPreference(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (!plugin)
            return null;

        return {
            mode: plugin.viewMode || null,
            enforced: plugin.viewModeEnforced === true
        };
    }

    function getGlobalVar(pluginId, varName, defaultValue) {
        if (globalVars[pluginId] && varName in globalVars[pluginId]) {
            return globalVars[pluginId][varName];
        }
        return defaultValue;
    }

    function setGlobalVar(pluginId, varName, value) {
        const newGlobals = Object.assign({}, globalVars);
        if (!newGlobals[pluginId]) {
            newGlobals[pluginId] = {};
        }
        newGlobals[pluginId] = Object.assign({}, newGlobals[pluginId]);
        newGlobals[pluginId][varName] = value;
        globalVars = newGlobals;
        globalVarChanged(pluginId, varName);
    }

    function checkPluginCompatibility(requiresVgs) {
        if (!requiresVgs)
            return true;
        return ShellVersionService.checkVersionRequirement(requiresVgs, ShellVersionService.getParsedShellVersion());
    }

    // Why a package claiming this id was REFUSED on its declared shell
    // requirement, or "" when none was. One owner for the sentence, because it
    // has to read identically in Settings > Plugins and in `plugin-scan`.
    //
    // The requirement is enforced in EXACTLY ONE PLACE: `_gateThenSwap`, which
    // is reached only for a package that declares itself the override of a
    // bundled id, or one displacing a package already loaded under that id.
    // `runStartupGate()`, `loadPlugin()` and `reloadPlugin()` do not look at
    // `requires_shell` at all, so a unique-id user or system package with an
    // impossible requirement LOADS. Verified in the nested sandbox: a fixture
    // declaring `>=99.0.0` against a 0.1.0 shell answered `plugin-scan status`
    // with `loaded`, alongside a control with a satisfiable requirement and one
    // with none, all three behaving identically.
    //
    // So this reports refusals, not declarations. An earlier version of this
    // function reported any non-bundled package with an unmet requirement,
    // which labelled loaded, working plugins "Unavailable" — the same false
    // report the bundled exemption exists to prevent, one source over.
    function requirementBlockReason(pluginId) {
        const shellSemver = ShellVersionService.semverVersion;
        const parts = [];
        for (const manifestPath in knownManifests) {
            if (pathToPluginId[manifestPath] !== pluginId)
                continue;
            const meta = knownManifests[manifestPath];
            if (!meta || meta.bad)
                continue;
            const requires = meta.refusedOnRequirement;
            const compatible = requires ? checkPluginCompatibility(requires) : true;
            if (!_withheldOnRequirement(meta, shellSemver, compatible))
                continue;
            // Phrased from the manifest's OWN source. Hardcoding "override"
            // mislabels a system-installed package as something the user put
            // there by hand, and the two are fixed in different places.
            let descriptor = I18n.tr("an installed package");
            if (meta.source === "user")
                descriptor = I18n.tr("an installed user package");
            else if (meta.source === "system")
                descriptor = I18n.tr("a system-installed package");
            parts.push(I18n.tr("%1 requires VGS %2 and was refused").arg(descriptor).arg(requires));
        }
        // EVERY refusal, not the first one found. Several packages can claim one
        // id, and reporting one of them sends the reader to fix a package that
        // may not be the one they installed.
        if (parts.length === 0)
            return "";
        return parts.join("; ") + " " + I18n.tr("(this shell is VGS %1)").arg(shellSemver);
    }

    // BEGIN REQUIREMENT REPORT POLICY
    // Pure: no QML API, no service calls, no side effects.
    // scripts/test-plugin-requirement-report.js extracts this block verbatim
    // and pairs it with ShellVersionService's own VERSION POLICY comparator, so
    // the rule is judged by the runtime's code rather than a re-implementation.
    // Keep it free of anything node cannot evaluate.
    //
    // `meta` is a knownManifests entry:
    // {source, requiresShell, demoted, refusedOnRequirement}. Every manifest
    // claiming an id is examined, not just the one that won it — a refused
    // package no longer owns the id, so looking only at the winner never sees
    // the very configuration this reports (VGS-76's motivating case).
    //
    // Keyed on `refusedOnRequirement`, which `_gateThenSwap` records at the
    // moment it refuses, NOT on `demoted`. `demoted` says a package lost its id
    // and says nothing about why: a package can fail its own startupCheck and
    // be demoted while its shell requirement is unmet but was never judged —
    // shell-version detection is asynchronous, so during the first scan the
    // version branch is skipped entirely. Inferring the cause from `demoted`
    // plus an unmet constraint therefore blamed the version for refusals that
    // had another cause.
    //
    // True only when a package was genuinely refused on the requirement:
    //   * nothing recorded, nothing was refused on this;
    //   * a bundled id is always-available by construction, so its declaration
    //     is inert — audited at its source, never enforced. It cannot reach the
    //     refusal path, and the guard stays explicit rather than implied;
    //   * shell version detection is asynchronous, and an unresolved version
    //     parses as 0.0.0 and fails every `>=`. Nothing is refused until it
    //     lands, so reporting then would be a lie that clears itself;
    //   * a constraint that is satisfied NOW is a stale record — the shell was
    //     upgraded under a refusal that has not been re-judged. Reporting it
    //     would send the reader after a problem that no longer exists.
    function _withheldOnRequirement(meta, shellSemver, compatible) {
        if (!meta || !meta.refusedOnRequirement)
            return false;
        if (meta.source === "bundled")
            return false;
        if (!shellSemver)
            return false;
        return !compatible;
    }
    // END REQUIREMENT REPORT POLICY

    function getIncompatiblePlugins() {
        const result = [];
        for (const pluginId in availablePlugins) {
            const plugin = availablePlugins[pluginId];
            if (plugin.loaded && plugin.requires_vgs && !checkPluginCompatibility(plugin.requires_vgs)) {
                result.push(plugin);
            }
        }
        return result;
    }

    readonly property string _ipcIdPattern: "^[a-zA-Z0-9_\\-:]{1,64}$";

    IpcHandler {
        target: "plugin-scan"

        function scan(): string {
            root.scanPlugins();
            return `SCAN_TRIGGERED: ${Object.keys(root.availablePlugins).length} known before debounce`;
        }

        function rescan(pluginId: string): string {
            if (!pluginId)
                return "ERROR: rescan requires a pluginId";
            if (!new RegExp(root._ipcIdPattern).test(pluginId))
                return `ERROR: invalid pluginId '${pluginId}' (allowed: [a-zA-Z0-9_\\-:]{1,64})`;
            // Not gated on availablePlugins alone. An id whose packages all
            // lost it — a demotion or a bare collision that ended with no
            // owner — is exactly the state this command exists to repair, and
            // it is the state in which the id has no record. Refusing it here
            // meant the recovery path could never run: rescanning is what drops
            // the blocked/demoted flags and re-reads the manifests. Known
            // manifest paths are the real precondition. (VGS-75)
            if (!(pluginId in root.availablePlugins) && !root._knownPathsFor(pluginId).length)
                return `ERROR: unknown pluginId '${pluginId}' (try 'list' first)`;
            if (!root.forceRescanPlugin(pluginId))
                return `ERROR: no manifest on disk for '${pluginId}'`;
            return `RESCAN_TRIGGERED: ${pluginId}`;
        }

        function reload(pluginId: string): string {
            if (!pluginId)
                return "ERROR: reload requires a pluginId";
            if (!new RegExp(root._ipcIdPattern).test(pluginId))
                return `ERROR: invalid pluginId '${pluginId}' (allowed: [a-zA-Z0-9_\\-:]{1,64})`;
            if (!(pluginId in root.availablePlugins))
                return `ERROR: unknown pluginId '${pluginId}'`;
            root.reloadPlugin(pluginId);
            return `RELOAD_TRIGGERED: ${pluginId}`;
        }

        function list(): string {
            const ids = Object.keys(root.availablePlugins);
            const cap = 256;
            const n = Math.min(ids.length, cap);
            const lines = [];
            for (let i = 0; i < n; i++) {
                const id = ids[i];
                if (!new RegExp(root._ipcIdPattern).test(id))
                    continue;
                const p = root.availablePlugins[id];
                const safeName = String(p.name || "").replace(/[\t\n\r]/g, " ");
                // Fifth field: why an unloaded package is being withheld, empty
                // when it is not. Without it a package enforced against by
                // requires_shell was indistinguishable here from one the user
                // simply had not enabled. (VGS-89)
                const withheld = String(root.requirementBlockReason(id)).replace(/[\t\n\r]/g, " ");
                lines.push(`${id}\t${p.loaded ? "loaded" : "unloaded"}\t${p.type || "unknown"}\t${safeName}\t${withheld}`);
            }
            const header = `# count=${ids.length} returned=${n}${ids.length > n ? " (truncated, see cap)" : ""}`;
            return header + "\n" + lines.join("\n");
        }

        function status(pluginId: string): string {
            if (!pluginId)
                return "ERROR: status requires a pluginId";
            if (!new RegExp(root._ipcIdPattern).test(pluginId))
                return `ERROR: invalid pluginId '${pluginId}'`;
            const plugin = root.availablePlugins[pluginId];
            if (!plugin)
                return `ERROR: unknown pluginId '${pluginId}'`;
            const errObj = root.pluginLoadErrors[pluginId];
            // A recorded startup failure first, then a standing refusal.
            //
            // The recorded error is emitted WITH its details. Emitting only the
            // title dropped the shell's own version — the requirement refusal
            // records "It requires VGS x." as the title and "This shell is VGS
            // y." as the details, and a reader given only the first cannot tell
            // whether their shell is too old or the plugin is mislabelled,
            // which is the whole point of reporting it.
            let err = "";
            if (errObj)
                err = errObj.details ? (errObj.title + " " + errObj.details) : (errObj.title || "");
            else
                err = root.requirementBlockReason(pluginId);
            const safeErr = String(err).replace(/[\t\n\r]/g, " ");
            return `${plugin.loaded ? "loaded" : "unloaded"}\t${plugin.type || ""}\t${safeErr}`;
        }
    }
}
