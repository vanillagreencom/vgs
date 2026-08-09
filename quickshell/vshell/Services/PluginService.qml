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
                // Before promoting: a removed bundled manifest must stop
                // marking the id always-available, or a same-id user package
                // stays auto-enabled and undisableable for the process
                // lifetime, and stays blocked from being promoted at all.
                _refreshBundledId(pid);
                if (!availablePlugins[pid])
                    promoteShadowedPlugin(pid);
            }
            _updateAvailablePluginsList();
            pluginListUpdated();
        }
    }

    function promoteShadowedPlugin(pluginId) {
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
        if (!bestPath)
            return;
        delete knownManifests[bestPath];
        loadPluginManifestFile(bestPath, bestSource, Date.now());
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
            existingPriority: existing ? _sourcePriority(existing.source) : -1
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
                    blocked: "bundled"
                };
                _reportBundledCollision(manifest.id, existing.source);
            }
            // The package this one displaces, if it is currently loaded. Its
            // teardown is deferred until the incoming package has passed its
            // own startup gate — unloading first is what left a product surface
            // with nothing loaded when an override turned out to be
            // non-viable. (VGS-24)
            const displaced = (existing && existing.loaded && existing.source !== sourceTag) ? existing : null;
            const newMap = Object.assign({}, availablePlugins);
            newMap[manifest.id] = info;
            availablePlugins = newMap;
            pathToPluginId[absPath] = manifest.id;
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag
            };
            if (displaced)
                info.loaded = false;
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
        } else {
            knownManifests[absPath] = {
                mtime: mtimeEpochMs,
                source: sourceTag,
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
        let action = "shadow";
        if (reclaims)
            action = "reclaim";
        else if (!existing || input.incomingPriority >= input.existingPriority)
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

        const requires = incoming.requires_shell;
        // Only once the shell version is actually known: it is detected by an
        // async Process, and an unresolved version parses as 0.0.0, which would
        // fail every `>=` requirement during the first scan. An override that
        // slips through that window is judged by the ShellVersionService
        // Connections below, once the version lands.
        if (requires && ShellVersionService.semverVersion && !checkPluginCompatibility(requires)) {
            giveUp(I18n.tr("It requires VGS %1.").arg(requires), null);
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
            for (const pluginId in root.availablePlugins) {
                const plugin = root.availablePlugins[pluginId];
                if (!plugin || plugin.overridesBundled !== true || !plugin.requires_shell)
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
        promoteShadowedPlugin(pluginId);
        _updateAvailablePluginsList();
        pluginListUpdated();
        const name = incoming ? (incoming.name || pluginId) : pluginId;
        log.warn("override failed to take over bundled id, demoting:", pluginId, reason);
        ToastService.showError(I18n.tr("Plugin override failed: %1").arg(name), I18n.tr("%1 could not start, so the version bundled with VGS is still in use.").arg(reason), "", "plugin-demoted-" + pluginId);
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
            return true;
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

    function forceRescanPlugin(pluginId) {
        const plugin = availablePlugins[pluginId];
        if (plugin && plugin.manifestPath) {
            const manifestPath = plugin.manifestPath;
            const source = plugin.source || "user";
            delete knownManifests[manifestPath];
            const newMap = Object.assign({}, availablePlugins);
            delete newMap[pluginId];
            availablePlugins = newMap;
            loadPluginManifestFile(manifestPath, source, Date.now());
        }
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
            if (!(pluginId in root.availablePlugins))
                return `ERROR: unknown pluginId '${pluginId}' (try 'list' first)`;
            root.forceRescanPlugin(pluginId);
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
                lines.push(`${id}\t${p.loaded ? "loaded" : "unloaded"}\t${p.type || "unknown"}\t${safeName}`);
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
            const err = errObj ? (errObj.title || "") : "";
            const safeErr = String(err).replace(/[\t\n\r]/g, " ");
            return `${plugin.loaded ? "loaded" : "unloaded"}\t${plugin.type || ""}\t${safeErr}`;
        }
    }
}
