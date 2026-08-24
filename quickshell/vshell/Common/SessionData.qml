pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "settings/SessionSpec.js" as Spec
import "settings/SessionStore.js" as Store

Singleton {
    id: root
    readonly property var log: Log.scoped("SessionData")

    readonly property int sessionConfigVersion: 3

    readonly property bool isGreeterMode: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    property bool _parseError: false
    property bool _hasLoaded: false
    property bool _isReadOnly: false
    property bool _hasUnsavedChanges: false
    property var _loadedSessionSnapshot: null
    readonly property var _hooks: ({
            "updateLocale": updateLocale
        })
    readonly property string _stateUrl: StandardPaths.writableLocation(StandardPaths.GenericStateLocation)
    readonly property string _stateDir: Paths.strip(_stateUrl)

    property bool isLightMode: false
    property bool doNotDisturb: false
    property real doNotDisturbUntil: 0
    property string terminalOverride: ""
    property bool isSwitchingMode: false
    property bool suppressOSD: true

    // Terminal resolution has exactly one owner: `vshell terminal` (VGS-32).
    // Nothing in QML picks a terminal — this list only populates the Settings
    // picker, and it is what the resolver itself found, in its own order.
    // `terminalOverride` is a stored preference the resolver reads back out of
    // session.json; it is not resolved here.
    readonly property var terminalOptions: ["ghostty", "kitty", "foot", "alacritty", "wezterm", "konsole", "gnome-terminal", "xterm"]
    property var installedTerminals: []

    Process {
        id: terminalProbe
        running: true
        command: [Paths.vshellCli, "terminal", "resolve", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const payload = JSON.parse(text || "{}");
                    const seen = [];
                    for (const candidate of (payload.candidates || [])) {
                        const exe = String(candidate[0] || "").split("/").pop();
                        if (exe && exe !== "xdg-terminal-exec" && seen.indexOf(exe) === -1)
                            seen.push(exe);
                    }
                    root.installedTerminals = seen;
                } catch (e) {
                    root.installedTerminals = [];
                }
            }
        }
    }

    Timer {
        id: dndExpireTimer
        repeat: false
        running: false
        onTriggered: root.setDoNotDisturb(false)
    }

    function _armDndExpireTimer() {
        dndExpireTimer.stop();
        if (!doNotDisturb || doNotDisturbUntil <= 0)
            return;
        const remaining = doNotDisturbUntil - Date.now();
        if (remaining <= 0) {
            setDoNotDisturb(false);
            return;
        }
        dndExpireTimer.interval = remaining;
        dndExpireTimer.start();
    }

    onDoNotDisturbChanged: _armDndExpireTimer()
    onDoNotDisturbUntilChanged: _armDndExpireTimer()

    Timer {
        id: osdSuppressTimer
        interval: 2000
        running: true
        onTriggered: root.suppressOSD = false
    }

    function suppressOSDTemporarily() {
        suppressOSD = true;
        osdSuppressTimer.restart();
    }

    Connections {
        target: SessionService
        function onSessionResumed() {
            root.suppressOSD = true;
            osdSuppressTimer.restart();
            root._applyDndExpirySanity();
        }
    }

    property string wallpaperPath: ""
    property bool perMonitorWallpaper: false
    property var monitorWallpapers: ({})
    property bool perModeWallpaper: false
    property string wallpaperPathLight: ""
    property string wallpaperPathDark: ""
    property var monitorWallpapersLight: ({})
    property var monitorWallpapersDark: ({})
    property var monitorWallpaperFillModes: ({})

    // Map: screenName -> { scrollX, scrollY } (0-100 range, like workspace percentage)
    property var monitorScrollPositions: ({})

    function setMonitorScrollPosition(screenName, scrollX, scrollY) {
        var newPositions = Object.assign({}, monitorScrollPositions);
        newPositions[screenName] = { scrollX: scrollX, scrollY: scrollY };
        monitorScrollPositions = newPositions;
    }

    function getMonitorScrollPosition(screenName) {
        return monitorScrollPositions[screenName] || { scrollX: 50, scrollY: 50 };
    }

    function clearMonitorScrollPosition(screenName) {
        var newPositions = Object.assign({}, monitorScrollPositions);
        delete newPositions[screenName];
        monitorScrollPositions = newPositions;
    }

    property string wallpaperTransition: "fade"
    readonly property var availableWallpaperTransitions: ["none", "fade", "wipe", "disc", "stripes", "iris bloom", "pixelate", "portal"]
    property var includedTransitions: availableWallpaperTransitions.filter(t => t !== "none")

    property bool wallpaperCyclingEnabled: false
    property string wallpaperCyclingMode: "interval"
    property int wallpaperCyclingInterval: 300
    property string wallpaperCyclingTime: "06:00"
    property var monitorCyclingSettings: ({})

    property bool nightModeEnabled: false
    property int nightModeTemperature: 4500
    property int nightModeHighTemperature: 6500
    property bool nightModeAutoEnabled: false
    property string nightModeAutoMode: "time"
    property int nightModeStartHour: 18
    property int nightModeStartMinute: 0
    property int nightModeEndHour: 6
    property int nightModeEndMinute: 0
    property real latitude: 0.0
    property real longitude: 0.0
    property bool nightModeUseIPLocation: false
    property string nightModeLocationProvider: ""

    property bool themeModeAutoEnabled: false
    property string themeModeAutoMode: "time"
    property int themeModeStartHour: 18
    property int themeModeStartMinute: 0
    property int themeModeEndHour: 6
    property int themeModeEndMinute: 0
    property bool themeModeShareGammaSettings: true
    property string themeModeNextTransition: ""

    property var pinnedApps: []
    property var barPinnedApps: []
    property int dockLauncherPosition: 0
    property var hiddenTrayIds: []
    property var trayItemOrder: []
    property var recentColors: []
    property bool showThirdPartyPlugins: false
    property bool pluginBrowserInstalledFirst: false
    property bool pluginBrowserHideInstalled: true
    property string pluginBrowserSortMode: "default"
    property string launchPrefix: ""
    property string lastBrightnessDevice: ""
    property var brightnessExponentialDevices: ({})
    property var brightnessUserSetValues: ({})
    property var brightnessExponentValues: ({})

    property int selectedGpuIndex: 0
    property bool nvidiaGpuTempEnabled: false
    property bool nonNvidiaGpuTempEnabled: false
    property var enabledGpuPciIds: []

    property string wifiDeviceOverride: ""
    property bool weatherHourlyDetailed: true

    property string weatherLocation: "New York, NY"
    property string weatherCoordinates: "40.7128,-74.0060"

    property var hiddenApps: []
    property var appOverrides: ({})
    property bool searchAppActions: true

    property string vpnLastConnected: ""

    property string lastPlayerIdentity: ""

    property var deviceMaxVolumes: ({})
    property var hiddenOutputDeviceNames: []
    property var hiddenInputDeviceNames: []

    property string locale: ""
    property string timeLocale: ""

    property string launcherLastFileSearchType: "all"
    property string launcherLastQuery: ""
    property var launcherQueryHistory: []
    property string niriOverviewLastMode: "apps"
    property string settingsSidebarExpandedIds: ","
    property string settingsSidebarCollapsedIds: ","

    Component.onCompleted: {
        if (!isGreeterMode) {
            loadSettings();
        }
    }

    property var _pendingMigration: null

    function loadSettings() {
        _hasUnsavedChanges = false;
        _pendingMigration = null;

        if (isGreeterMode) {
            parseSettings(greeterSessionFile.text());
            return;
        }

        try {
            const txt = settingsFile.text();
            let obj = (txt && txt.trim()) ? JSON.parse(txt) : {};

            if (obj?.brightnessLogarithmicDevices && !obj?.brightnessExponentialDevices)
                obj.brightnessExponentialDevices = obj.brightnessLogarithmicDevices;

            if (obj?.nightModeStartTime !== undefined) {
                const parts = obj.nightModeStartTime.split(":");
                obj.nightModeStartHour = parseInt(parts[0]) || 18;
                obj.nightModeStartMinute = parseInt(parts[1]) || 0;
            }
            if (obj?.nightModeEndTime !== undefined) {
                const parts = obj.nightModeEndTime.split(":");
                obj.nightModeEndHour = parseInt(parts[0]) || 6;
                obj.nightModeEndMinute = parseInt(parts[1]) || 0;
            }

            const oldVersion = obj?.configVersion ?? 0;
            if (obj && oldVersion === 0)
                migrateFromUndefinedToV1(obj);

            if (obj && oldVersion < sessionConfigVersion) {
                const settingsDataRef = (typeof SettingsData !== "undefined") ? SettingsData : null;
                const migrated = Store.migrateToVersion(obj, sessionConfigVersion, settingsDataRef);
                if (migrated) {
                    _pendingMigration = migrated;
                    obj = migrated;
                }
            }

            Store.parse(root, obj);
            _applyDndExpirySanity();

            _loadedSessionSnapshot = getCurrentSessionJson();
            _hasLoaded = true;

            if (typeof WallpaperCyclingService !== "undefined")
                WallpaperCyclingService.updateCyclingState();

            _checkSessionWritable();
        } catch (e) {
            _parseError = true;
            const msg = e.message;
            log.error(`Failed to parse session.json - file will not be overwritten: ${msg}`);
            Qt.callLater(() => ToastService.showError(I18n.tr("Failed to parse session.json"), msg));
        }
    }

    function _checkSessionWritable() {
        sessionWritableCheckProcess.running = true;
    }

    function _onWritableCheckComplete(writable) {
        const wasReadOnly = _isReadOnly;
        _isReadOnly = !writable;
        if (_isReadOnly) {
            _hasUnsavedChanges = _checkForUnsavedChanges();
        } else {
            _loadedSessionSnapshot = getCurrentSessionJson();
            _hasUnsavedChanges = false;
            if (wasReadOnly && _pendingMigration)
                settingsFile.setText(JSON.stringify(_pendingMigration, null, 2));
        }
        _pendingMigration = null;
    }

    function _checkForUnsavedChanges() {
        if (!_hasLoaded || !_loadedSessionSnapshot)
            return false;
        const current = getCurrentSessionJson();
        return current !== _loadedSessionSnapshot;
    }

    function getCurrentSessionJson() {
        return JSON.stringify(Store.toJson(root), null, 2);
    }

    function parseSettings(content) {
        _parseError = false;
        try {
            let obj = (content && content.trim()) ? JSON.parse(content) : {};

            if (obj?.brightnessLogarithmicDevices && !obj?.brightnessExponentialDevices)
                obj.brightnessExponentialDevices = obj.brightnessLogarithmicDevices;

            if (obj?.nightModeStartTime !== undefined) {
                const parts = obj.nightModeStartTime.split(":");
                obj.nightModeStartHour = parseInt(parts[0]) || 18;
                obj.nightModeStartMinute = parseInt(parts[1]) || 0;
            }
            if (obj?.nightModeEndTime !== undefined) {
                const parts = obj.nightModeEndTime.split(":");
                obj.nightModeEndHour = parseInt(parts[0]) || 6;
                obj.nightModeEndMinute = parseInt(parts[1]) || 0;
            }

            const oldVersion = obj?.configVersion ?? 0;
            if (obj && oldVersion === 0)
                migrateFromUndefinedToV1(obj);

            if (obj && oldVersion < sessionConfigVersion) {
                const settingsDataRef = (typeof SettingsData !== "undefined") ? SettingsData : null;
                const migrated = Store.migrateToVersion(obj, sessionConfigVersion, settingsDataRef);
                if (migrated) {
                    _pendingMigration = migrated;
                    obj = migrated;
                }
            }

            Store.parse(root, obj);
            _applyDndExpirySanity();

            _loadedSessionSnapshot = getCurrentSessionJson();
            _hasLoaded = true;

            if (typeof WallpaperCyclingService !== "undefined")
                WallpaperCyclingService.updateCyclingState();
        } catch (e) {
            _parseError = true;
            const msg = e.message;
            log.error(`Failed to parse session.json - file will not be overwritten: ${msg}`);
            Qt.callLater(() => ToastService.showError(I18n.tr("Failed to parse session.json"), msg));
        }
    }

    function _applyDndExpirySanity() {
        if (doNotDisturb && doNotDisturbUntil > 0 && Date.now() >= doNotDisturbUntil) {
            doNotDisturb = false;
            doNotDisturbUntil = 0;
        } else if (!doNotDisturb && doNotDisturbUntil !== 0) {
            doNotDisturbUntil = 0;
        }
        _armDndExpireTimer();
    }

    function saveSettings() {
        if (isGreeterMode || _parseError || !_hasLoaded)
            return;
        settingsFile.setText(getCurrentSessionJson());
        if (_isReadOnly)
            _checkSessionWritable();
    }

    function set(key, value) {
        Spec.set(root, key, value, saveSettings, _hooks);
    }

    function migrateFromUndefinedToV1(settings) {
        if (typeof SettingsData !== "undefined") {
            if (settings.acMonitorTimeout !== undefined) {
                SettingsData.set("acMonitorTimeout", settings.acMonitorTimeout);
            }
            if (settings.acLockTimeout !== undefined) {
                SettingsData.set("acLockTimeout", settings.acLockTimeout);
            }
            if (settings.acSuspendTimeout !== undefined) {
                SettingsData.set("acSuspendTimeout", settings.acSuspendTimeout);
            }
            if (settings.acHibernateTimeout !== undefined) {
                SettingsData.set("acHibernateTimeout", settings.acHibernateTimeout);
            }
            if (settings.batteryMonitorTimeout !== undefined) {
                SettingsData.set("batteryMonitorTimeout", settings.batteryMonitorTimeout);
            }
            if (settings.batteryLockTimeout !== undefined) {
                SettingsData.set("batteryLockTimeout", settings.batteryLockTimeout);
            }
            if (settings.batterySuspendTimeout !== undefined) {
                SettingsData.set("batterySuspendTimeout", settings.batterySuspendTimeout);
            }
            if (settings.batteryHibernateTimeout !== undefined) {
                SettingsData.set("batteryHibernateTimeout", settings.batteryHibernateTimeout);
            }
            if (settings.lockBeforeSuspend !== undefined) {
                SettingsData.set("lockBeforeSuspend", settings.lockBeforeSuspend);
            }
            if (settings.loginctlLockIntegration !== undefined) {
                SettingsData.set("loginctlLockIntegration", settings.loginctlLockIntegration);
            }
            if (settings.launchPrefix !== undefined) {
                SettingsData.set("launchPrefix", settings.launchPrefix);
            }
        }
        if (typeof CacheData !== "undefined") {
            if (settings.wallpaperLastPath !== undefined) {
                CacheData.wallpaperLastPath = settings.wallpaperLastPath;
            }
            if (settings.profileLastPath !== undefined) {
                CacheData.profileLastPath = settings.profileLastPath;
            }
            CacheData.saveCache();
        }
    }

    function setLightMode(lightMode) {
        isSwitchingMode = true;
        syncWallpaperForCurrentMode(lightMode);
        isLightMode = lightMode;
        saveSettings();
        Qt.callLater(() => {
            isSwitchingMode = false;
        });
    }

    function setDoNotDisturb(enabled, durationMinutes) {
        const minutes = Number(durationMinutes) || 0;
        doNotDisturb = enabled;
        doNotDisturbUntil = (enabled && minutes > 0) ? Date.now() + minutes * 60 * 1000 : 0;
        saveSettings();
    }

    function setDoNotDisturbUntilTimestamp(timestampMs) {
        const target = Number(timestampMs) || 0;
        if (target <= Date.now()) {
            setDoNotDisturb(false);
            return;
        }
        doNotDisturb = true;
        doNotDisturbUntil = target;
        saveSettings();
    }

    function setWallpaperPath(path) {
        wallpaperPath = path;
        saveSettings();
    }

    // Under per-monitor mode each screen displays its own assignment and the
    // global path is invisible, so "set the wallpaper" must reach every
    // monitor or theme applies and browser clicks silently change nothing.
    // Single-screen assignment stays explicit via setMonitorWallpaper.
    function _propagateToAllMonitors(imagePath) {
        if (!perMonitorWallpaper)
            return;
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++)
            setMonitorWallpaper(screens[i].name, imagePath);
    }

    function setWallpaper(imagePath) {
        wallpaperPath = imagePath;
        if (perModeWallpaper) {
            if (isLightMode) {
                wallpaperPathLight = imagePath;
            } else {
                wallpaperPathDark = imagePath;
            }
        }
        _propagateToAllMonitors(imagePath);
        saveSettings();
    }

    function setWallpaperColor(color) {
        wallpaperPath = color;
        if (perModeWallpaper) {
            if (isLightMode) {
                wallpaperPathLight = color;
            } else {
                wallpaperPathDark = color;
            }
        }
        _propagateToAllMonitors(color);
        saveSettings();
    }

    function clearWallpaper() {
        wallpaperPath = "";
        _propagateToAllMonitors("");
        saveSettings();
    }

    function setModeWallpaper(mode, imagePath) {
        if (mode !== "light" && mode !== "dark")
            return;
        if (!perModeWallpaper)
            setPerModeWallpaper(true);
        if (mode === "light")
            wallpaperPathLight = imagePath;
        else
            wallpaperPathDark = imagePath;
        if (perMonitorWallpaper) {
            // Fill the per-monitor map for that mode too, else nothing displays it.
            var screens = Quickshell.screens;
            var modeMap = Object.assign({}, mode === "light" ? monitorWallpapersLight : monitorWallpapersDark);
            for (var i = 0; i < screens.length; i++) {
                var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screens[i]) : screens[i].name;
                modeMap[identifier] = imagePath;
            }
            if (mode === "light")
                monitorWallpapersLight = modeMap;
            else
                monitorWallpapersDark = modeMap;
            if ((mode === "light") === isLightMode)
                _propagateToAllMonitors(imagePath);
        }
        if ((mode === "light") === isLightMode)
            wallpaperPath = imagePath;
        saveSettings();
    }

    function setPerMonitorWallpaper(enabled) {
        perMonitorWallpaper = enabled;
        if (enabled && perModeWallpaper) {
            syncWallpaperForCurrentMode();
        }
        saveSettings();
    }

    function setPerModeWallpaper(enabled) {
        if (enabled && wallpaperCyclingEnabled) {
            setWallpaperCyclingEnabled(false);
        }
        if (enabled && perMonitorWallpaper) {
            var monitorCyclingAny = false;
            for (var key in monitorCyclingSettings) {
                if (monitorCyclingSettings[key].enabled) {
                    monitorCyclingAny = true;
                    break;
                }
            }
            if (monitorCyclingAny) {
                var newSettings = Object.assign({}, monitorCyclingSettings);
                for (var screenName in newSettings) {
                    newSettings[screenName].enabled = false;
                }
                monitorCyclingSettings = newSettings;
            }
        }

        perModeWallpaper = enabled;
        if (enabled) {
            if (perMonitorWallpaper) {
                monitorWallpapersLight = Object.assign({}, monitorWallpapers);
                monitorWallpapersDark = Object.assign({}, monitorWallpapers);
            } else {
                wallpaperPathLight = wallpaperPath;
                wallpaperPathDark = wallpaperPath;
            }
        } else {
            syncWallpaperForCurrentMode();
        }
        saveSettings();
    }

    // The one screen lookup: every per-monitor writer walked Quickshell.screens
    // for this.
    function _screenByName(screenName) {
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            if (screens[i].name === screenName)
                return screens[i];
        }
        return null;
    }

    // One screen's entry in one per-monitor map, as a NEW map so the property
    // change is seen. The screen's OTHER keys go with it: an assignment an
    // earlier session wrote under the raw name or model is answered by
    // _findMonitorValue BEFORE the display name written here, so leaving one
    // behind means the value just written is not the one read back.
    function _mapWithMonitorValue(map, screen, value) {
        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;
        var next = {};
        for (var key in map) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model) || key === identifier;
            if (!isThisScreen)
                next[key] = map[key];
        }
        if (value && value !== "")
            next[identifier] = value;
        return next;
    }

    // Turn per-monitor mode ON without changing what any monitor shows.
    //
    // setPerMonitorWallpaper alone only flips the flag: monitorWallpapers —
    // and, under per-mode, the light/dark maps syncWallpaperForCurrentMode
    // refills it from — keep whatever an earlier per-monitor session left in
    // them, and getMonitorWallpaper starts answering those the instant the
    // flag goes on. Every screen holding a retained entry therefore JUMPS to
    // an old wallpaper the moment the mode is enabled (VGS-212). Seeding each
    // connected screen from what it displays right now makes the flip
    // invisible, so only the caller's own write afterwards changes anything.
    //
    // The mirror of setPerModeWallpaper's own enable seeding, which copies the
    // live values into the maps it is about to start reading.
    function enablePerMonitorWallpaperFromCurrent() {
        if (perMonitorWallpaper)
            return;
        var screens = Quickshell.screens || [];
        for (var i = 0; i < screens.length; i++) {
            var screen = screens[i];
            var shown = getMonitorWallpaper(screen.name);
            monitorWallpapers = _mapWithMonitorValue(monitorWallpapers, screen, shown);
            // BOTH mode maps, not just the current one: after the flip a
            // light/dark switch refills monitorWallpapers from the OTHER map,
            // and an unseeded one jumps every screen exactly as the flag flip
            // would. The CURRENT mode is seeded from what is ON the screen
            // rather than from its global path — wallpaper cycling writes
            // wallpaperPath alone, so the two can disagree — and the other
            // mode from its own.
            if (perModeWallpaper) {
                monitorWallpapersLight = _mapWithMonitorValue(monitorWallpapersLight, screen, isLightMode ? shown : wallpaperPathLight);
                monitorWallpapersDark = _mapWithMonitorValue(monitorWallpapersDark, screen, isLightMode ? wallpaperPathDark : shown);
            }
        }
        setPerMonitorWallpaper(true);
    }

    function setMonitorWallpaper(screenName, path) {
        var screen = _screenByName(screenName);
        if (!screen) {
            log.warn("Screen not found");
            return;
        }

        monitorWallpapers = _mapWithMonitorValue(monitorWallpapers, screen, path);

        if (perModeWallpaper) {
            if (isLightMode)
                monitorWallpapersLight = _mapWithMonitorValue(monitorWallpapersLight, screen, path);
            else
                monitorWallpapersDark = _mapWithMonitorValue(monitorWallpapersDark, screen, path);
        }

        saveSettings();
    }

    function setWallpaperTransition(transition) {
        wallpaperTransition = transition;
        saveSettings();
    }

    function setWallpaperCyclingEnabled(enabled) {
        wallpaperCyclingEnabled = enabled;
        saveSettings();
    }

    function setWallpaperCyclingMode(mode) {
        wallpaperCyclingMode = mode;
        saveSettings();
    }

    function setWallpaperCyclingInterval(interval) {
        wallpaperCyclingInterval = interval;
        saveSettings();
    }

    function setWallpaperCyclingTime(time) {
        wallpaperCyclingTime = time;
        saveSettings();
    }

    function setMonitorCyclingEnabled(screenName, enabled) {
        var screen = _screenByName(screenName);
        if (!screen) {
            log.warn("Screen not found");
            return;
        }

        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;

        var newSettings = {};
        for (var key in monitorCyclingSettings) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model);
            if (!isThisScreen) {
                newSettings[key] = monitorCyclingSettings[key];
            }
        }

        newSettings[identifier] = getMonitorCyclingSettings(screenName);
        newSettings[identifier].enabled = enabled;
        monitorCyclingSettings = newSettings;
        saveSettings();
    }

    function setMonitorCyclingMode(screenName, mode) {
        var screen = _screenByName(screenName);
        if (!screen) {
            log.warn("Screen not found");
            return;
        }

        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;

        var newSettings = {};
        for (var key in monitorCyclingSettings) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model);
            if (!isThisScreen) {
                newSettings[key] = monitorCyclingSettings[key];
            }
        }

        newSettings[identifier] = getMonitorCyclingSettings(screenName);
        newSettings[identifier].mode = mode;
        monitorCyclingSettings = newSettings;
        saveSettings();
    }

    function setMonitorCyclingInterval(screenName, interval) {
        var screen = _screenByName(screenName);
        if (!screen) {
            log.warn("Screen not found");
            return;
        }

        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;

        var newSettings = {};
        for (var key in monitorCyclingSettings) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model);
            if (!isThisScreen) {
                newSettings[key] = monitorCyclingSettings[key];
            }
        }

        newSettings[identifier] = getMonitorCyclingSettings(screenName);
        newSettings[identifier].interval = interval;
        monitorCyclingSettings = newSettings;
        saveSettings();
    }

    function setMonitorCyclingTime(screenName, time) {
        var screen = _screenByName(screenName);
        if (!screen) {
            log.warn("Screen not found");
            return;
        }

        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;

        var newSettings = {};
        for (var key in monitorCyclingSettings) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model);
            if (!isThisScreen) {
                newSettings[key] = monitorCyclingSettings[key];
            }
        }

        newSettings[identifier] = getMonitorCyclingSettings(screenName);
        newSettings[identifier].time = time;
        monitorCyclingSettings = newSettings;
        saveSettings();
    }

    function setNightModeEnabled(enabled) {
        nightModeEnabled = enabled;
        saveSettings();
    }

    function setNightModeTemperature(temperature) {
        nightModeTemperature = temperature;
        saveSettings();
    }

    function setNightModeHighTemperature(temperature) {
        nightModeHighTemperature = temperature;
        saveSettings();
    }

    function setNightModeAutoEnabled(enabled) {
        nightModeAutoEnabled = enabled;
        saveSettings();
    }

    function setNightModeAutoMode(mode) {
        nightModeAutoMode = mode;
        saveSettings();
    }

    function setNightModeStartHour(hour) {
        nightModeStartHour = hour;
        saveSettings();
    }

    function setNightModeStartMinute(minute) {
        nightModeStartMinute = minute;
        saveSettings();
    }

    function setNightModeEndHour(hour) {
        nightModeEndHour = hour;
        saveSettings();
    }

    function setNightModeEndMinute(minute) {
        nightModeEndMinute = minute;
        saveSettings();
    }

    function setNightModeUseIPLocation(use) {
        nightModeUseIPLocation = use;
        saveSettings();
    }

    function setLatitude(lat) {
        latitude = lat;
        saveSettings();
    }

    function setLongitude(lng) {
        longitude = lng;
        saveSettings();
    }

    function setNightModeLocationProvider(provider) {
        nightModeLocationProvider = provider;
        saveSettings();
    }

    function setThemeModeAutoEnabled(enabled) {
        themeModeAutoEnabled = enabled;
        saveSettings();
    }

    function setThemeModeAutoMode(mode) {
        themeModeAutoMode = mode;
        saveSettings();
    }

    function setThemeModeStartHour(hour) {
        themeModeStartHour = hour;
        saveSettings();
    }

    function setThemeModeStartMinute(minute) {
        themeModeStartMinute = minute;
        saveSettings();
    }

    function setThemeModeEndHour(hour) {
        themeModeEndHour = hour;
        saveSettings();
    }

    function setThemeModeEndMinute(minute) {
        themeModeEndMinute = minute;
        saveSettings();
    }

    function setThemeModeShareGammaSettings(share) {
        themeModeShareGammaSettings = share;
        saveSettings();
    }

    function setPinnedApps(apps) {
        pinnedApps = apps;
        saveSettings();
    }

    function setDockLauncherPosition(position) {
        dockLauncherPosition = position;
        saveSettings();
    }

    function addPinnedApp(appId) {
        if (!appId)
            return;
        var currentPinned = [...pinnedApps];
        if (currentPinned.indexOf(appId) === -1) {
            currentPinned.push(appId);
            setPinnedApps(currentPinned);
        }
    }

    function removePinnedApp(appId) {
        if (!appId)
            return;
        var currentPinned = pinnedApps.filter(id => id !== appId);
        setPinnedApps(currentPinned);
    }

    function isPinnedApp(appId) {
        return appId && pinnedApps.indexOf(appId) !== -1;
    }

    function setBarPinnedApps(apps) {
        barPinnedApps = apps;
        saveSettings();
    }

    function addBarPinnedApp(appId) {
        if (!appId)
            return;
        var currentPinned = [...barPinnedApps];
        if (currentPinned.indexOf(appId) === -1) {
            currentPinned.push(appId);
            setBarPinnedApps(currentPinned);
        }
    }

    function removeBarPinnedApp(appId) {
        if (!appId)
            return;
        var currentPinned = barPinnedApps.filter(id => id !== appId);
        setBarPinnedApps(currentPinned);
    }

    function isBarPinnedApp(appId) {
        return appId && barPinnedApps.indexOf(appId) !== -1;
    }

    function hideTrayId(trayId) {
        if (!trayId)
            return;
        const current = [...hiddenTrayIds];
        if (current.indexOf(trayId) === -1) {
            current.push(trayId);
            hiddenTrayIds = current;
            saveSettings();
        }
    }

    function showTrayId(trayId) {
        if (!trayId)
            return;
        hiddenTrayIds = hiddenTrayIds.filter(id => id !== trayId);
        saveSettings();
    }

    function isHiddenTrayId(trayId) {
        return trayId && hiddenTrayIds.indexOf(trayId) !== -1;
    }

    function setTrayItemOrder(order) {
        trayItemOrder = order;
        saveSettings();
    }

    function addRecentColor(color) {
        const colorStr = color.toString();
        let recent = recentColors.slice();
        recent = recent.filter(c => c !== colorStr);
        recent.unshift(colorStr);
        if (recent.length > 5)
            recent = recent.slice(0, 5);
        recentColors = recent;
        saveSettings();
    }

    function setShowThirdPartyPlugins(enabled) {
        showThirdPartyPlugins = enabled;
        saveSettings();
    }

    function setPluginBrowserInstalledFirst(enabled) {
        pluginBrowserInstalledFirst = enabled;
        saveSettings();
    }

    function setPluginBrowserHideInstalled(enabled) {
        pluginBrowserHideInstalled = enabled;
        saveSettings();
    }

    function setPluginBrowserSortMode(mode) {
        if (mode === "type" || mode === "contributor")
            mode = "author";
        if (mode !== "default" && mode !== "name" && mode !== "author" && mode !== "category")
            mode = "default";
        pluginBrowserSortMode = mode;
        saveSettings();
    }

    function setLaunchPrefix(prefix) {
        launchPrefix = prefix;
        saveSettings();
    }

    function setLastBrightnessDevice(device) {
        lastBrightnessDevice = device;
        saveSettings();
    }

    function setBrightnessExponential(deviceName, enabled) {
        var newSettings = Object.assign({}, brightnessExponentialDevices);
        if (enabled) {
            newSettings[deviceName] = true;
        } else {
            delete newSettings[deviceName];
        }
        brightnessExponentialDevices = newSettings;
        saveSettings();

        if (typeof DisplayService !== "undefined") {
            DisplayService.updateDeviceBrightnessDisplay(deviceName);
        }
    }

    function getBrightnessExponential(deviceName) {
        return brightnessExponentialDevices[deviceName] === true;
    }

    function setBrightnessUserSetValue(deviceName, value) {
        var newValues = Object.assign({}, brightnessUserSetValues);
        newValues[deviceName] = value;
        brightnessUserSetValues = newValues;
        saveSettings();
    }

    function getBrightnessUserSetValue(deviceName) {
        return brightnessUserSetValues[deviceName];
    }

    function clearBrightnessUserSetValue(deviceName) {
        var newValues = Object.assign({}, brightnessUserSetValues);
        delete newValues[deviceName];
        brightnessUserSetValues = newValues;
        saveSettings();
    }

    function setBrightnessExponent(deviceName, exponent) {
        var newValues = Object.assign({}, brightnessExponentValues);
        if (exponent !== undefined && exponent !== null) {
            newValues[deviceName] = exponent;
        } else {
            delete newValues[deviceName];
        }
        brightnessExponentValues = newValues;
        saveSettings();
    }

    function getBrightnessExponent(deviceName) {
        const value = brightnessExponentValues[deviceName];
        return value !== undefined ? value : 1.2;
    }

    function setSelectedGpuIndex(index) {
        selectedGpuIndex = index;
        saveSettings();
    }

    function setNvidiaGpuTempEnabled(enabled) {
        nvidiaGpuTempEnabled = enabled;
        saveSettings();
    }

    function setNonNvidiaGpuTempEnabled(enabled) {
        nonNvidiaGpuTempEnabled = enabled;
        saveSettings();
    }

    function setEnabledGpuPciIds(pciIds) {
        enabledGpuPciIds = pciIds;
        saveSettings();
    }

    function setWifiDeviceOverride(device) {
        wifiDeviceOverride = device || "";
        saveSettings();
    }

    function setWeatherHourlyDetailed(detailed) {
        weatherHourlyDetailed = detailed;
        saveSettings();
    }

    function setWeatherLocation(displayName, coordinates) {
        weatherLocation = displayName;
        weatherCoordinates = coordinates;
        saveSettings();
    }

    function hideApp(appId) {
        if (!appId)
            return;
        const current = [...hiddenApps];
        if (current.indexOf(appId) === -1) {
            current.push(appId);
            hiddenApps = current;
            saveSettings();
        }
    }

    function showApp(appId) {
        if (!appId)
            return;
        hiddenApps = hiddenApps.filter(id => id !== appId);
        saveSettings();
    }

    function isAppHidden(appId) {
        return appId && hiddenApps.indexOf(appId) !== -1;
    }

    function setAppOverride(appId, overrides) {
        if (!appId)
            return;
        const newOverrides = Object.assign({}, appOverrides);
        if (!overrides || Object.keys(overrides).length === 0) {
            delete newOverrides[appId];
        } else {
            newOverrides[appId] = overrides;
        }
        appOverrides = newOverrides;
        saveSettings();
    }

    function getAppOverride(appId) {
        if (!appId)
            return null;
        return appOverrides[appId] || null;
    }

    function clearAppOverride(appId) {
        if (!appId)
            return;
        const newOverrides = Object.assign({}, appOverrides);
        delete newOverrides[appId];
        appOverrides = newOverrides;
        saveSettings();
    }

    function setSearchAppActions(enabled) {
        searchAppActions = enabled;
        saveSettings();
    }

    function setVpnLastConnected(uuid) {
        vpnLastConnected = uuid || "";
        saveSettings();
    }

    function setDeviceMaxVolume(nodeName, maxPercent) {
        if (!nodeName)
            return;
        const updated = Object.assign({}, deviceMaxVolumes);
        const clamped = Math.max(100, Math.min(200, Math.round(maxPercent)));
        if (clamped === 100) {
            delete updated[nodeName];
        } else {
            updated[nodeName] = clamped;
        }
        deviceMaxVolumes = updated;
        saveSettings();
    }

    function setHiddenOutputDeviceNames(deviceNames) {
        if (!Array.isArray(deviceNames))
            return;
        hiddenOutputDeviceNames = deviceNames;
        saveSettings();
    }

    function setHiddenInputDeviceNames(deviceNames) {
        if (!Array.isArray(deviceNames))
            return;
        hiddenInputDeviceNames = deviceNames;
        saveSettings();
    }

    function getDeviceMaxVolume(nodeName) {
        if (!nodeName)
            return 100;
        return deviceMaxVolumes[nodeName] ?? 100;
    }

    function removeDeviceMaxVolume(nodeName) {
        if (!nodeName)
            return;
        const updated = Object.assign({}, deviceMaxVolumes);
        delete updated[nodeName];
        deviceMaxVolumes = updated;
        saveSettings();
    }

    function updateLocale() {
        if (!locale) {
            I18n._pickTranslation();
            return;
        }
        I18n.useLocale(locale, locale.startsWith("en") ? "" : I18n.folder + "/" + locale + ".json");
    }

    function setLauncherLastFileSearchType(type) {
        launcherLastFileSearchType = type;
        saveSettings();
    }

    function setLauncherLastQuery(query) {
        launcherLastQuery = query;
        saveSettings();
    }

    function addLauncherHistory(query) {
        let q = query.trim();

        setLauncherLastQuery(q);

        if (!q)
            return;

        if (launcherQueryHistory.length > 0 && launcherQueryHistory[0] === q) {
            return;
        }

        let history = [...launcherQueryHistory];

        let idx = history.indexOf(q);
        if (idx !== -1)
            history.splice(idx, 1);

        history.unshift(q);
        if (history.length > 50)
            history = history.slice(0, 50);

        launcherQueryHistory = history;
        saveSettings();
    }

    // The inverse of addLauncherHistory above, so it clears the same property
    // that one writes. It said `launcherSearchHistory` — a name declared
    // nowhere — which would have thrown at runtime, after launcherLastQuery
    // was already blanked and before saveSettings() ran.
    function clearLauncherHistory() {
        launcherLastQuery = "";
        launcherQueryHistory = [];
        saveSettings();
    }

    function setNiriOverviewLastMode(mode) {
        niriOverviewLastMode = mode;
        saveSettings();
    }

    function setSettingsSidebarState(expandedIds, collapsedIds) {
        settingsSidebarExpandedIds = expandedIds;
        settingsSidebarCollapsedIds = collapsedIds;
        saveSettings();
    }

    function syncWallpaperForCurrentMode(mode) {
        if (!perModeWallpaper)
            return;
        var light = (mode !== undefined) ? mode : isLightMode;
        if (perMonitorWallpaper) {
            monitorWallpapers = light ? Object.assign({}, monitorWallpapersLight) : Object.assign({}, monitorWallpapersDark);
            return;
        }

        wallpaperPath = light ? wallpaperPathLight : wallpaperPathDark;
    }

    function _findMonitorValue(map, screenName) {
        var screen = _screenByName(screenName);
        if (!screen)
            return map[screenName];

        if (map[screen.name] !== undefined)
            return map[screen.name];
        if (screen.model && map[screen.model] !== undefined)
            return map[screen.model];
        if (typeof SettingsData !== "undefined") {
            var displayName = SettingsData.getScreenDisplayName(screen);
            if (displayName && map[displayName] !== undefined)
                return map[displayName];
        }
        return undefined;
    }

    function getMonitorWallpaper(screenName) {
        if (!perMonitorWallpaper)
            return wallpaperPath;
        var value = _findMonitorValue(monitorWallpapers, screenName);
        return value !== undefined ? value : wallpaperPath;
    }

    function getMonitorWallpaperFillMode(screenName) {
        var globalFillMode = (typeof SettingsData !== "undefined") ? SettingsData.wallpaperFillMode : "Fill";
        if (!perMonitorWallpaper)
            return globalFillMode;
        var value = _findMonitorValue(monitorWallpaperFillModes, screenName);
        return value !== undefined ? value : globalFillMode;
    }

    function setMonitorWallpaperFillMode(screenName, mode) {
        var screen = _screenByName(screenName);
        if (!screen)
            return;

        var identifier = typeof SettingsData !== "undefined" ? SettingsData.getScreenDisplayName(screen) : screen.name;

        var newModes = {};
        for (var key in monitorWallpaperFillModes) {
            var isThisScreen = key === screen.name || (screen.model && key === screen.model);
            if (!isThisScreen)
                newModes[key] = monitorWallpaperFillModes[key];
        }

        newModes[identifier] = mode;
        monitorWallpaperFillModes = newModes;
        saveSettings();
    }

    function getMonitorCyclingSettings(screenName) {
        var defaults = {
            "enabled": false,
            "mode": "interval",
            "interval": 300,
            "time": "06:00"
        };
        var value = _findMonitorValue(monitorCyclingSettings, screenName);
        return Object.assign({}, defaults, value !== undefined ? value : {});
    }

    FileView {
        id: settingsFile

        path: isGreeterMode ? "" : StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vshell/session.json"
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: !isGreeterMode
        onLoaded: {
            if (!isGreeterMode) {
                _hasUnsavedChanges = false;
                parseSettings(settingsFile.text());
            }
        }
        onSaveFailed: error => {
            root._isReadOnly = true;
            root._hasUnsavedChanges = root._checkForUnsavedChanges();
        }
    }

    readonly property string _greeterCacheDir: Quickshell.env("VSHELL_GREET_CFG_DIR") || "/var/cache/vshell-greeter"

    property string greeterSessionBaseDir: root._greeterCacheDir

    function setGreeterSessionBaseDir(dir) {
        const next = dir || root._greeterCacheDir;
        if (greeterSessionBaseDir === next)
            return;
        greeterSessionBaseDir = next;
        if (isGreeterMode)
            greeterSessionFile.reload();
    }

    function resetGreeterSessionBaseDir() {
        setGreeterSessionBaseDir(root._greeterCacheDir);
    }

    FileView {
        id: greeterSessionFile

        path: root.greeterSessionBaseDir ? (root.greeterSessionBaseDir + "/session.json") : ""
        preload: isGreeterMode
        blockLoading: false
        blockWrites: true
        watchChanges: false
        printErrors: true
        onLoaded: {
            if (isGreeterMode) {
                parseSettings(greeterSessionFile.text());
            }
        }
    }

    Process {
        id: sessionWritableCheckProcess

        property string sessionPath: Paths.strip(settingsFile.path)

        command: ["sh", "-c", "[ ! -f \"" + sessionPath + "\" ] || [ -w \"" + sessionPath + "\" ] && echo 'writable' || echo 'readonly'"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const result = text.trim();
                root._onWritableCheckComplete(result === "writable");
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        function get(): string {
            if (root.perMonitorWallpaper) {
                return "ERROR: Per-monitor mode enabled. Use getFor(screenName) instead.";
            }
            return root.wallpaperPath || "";
        }

        function set(path: string): string {
            if (root.perMonitorWallpaper) {
                return "ERROR: Per-monitor mode enabled. Use setFor(screenName, path) instead.";
            }

            if (!path) {
                return "ERROR: No path provided";
            }

            var absolutePath = path.startsWith("/") ? path : StandardPaths.writableLocation(StandardPaths.HomeLocation) + "/" + path;

            try {
                root.setWallpaper(absolutePath);
                return "SUCCESS: Wallpaper set to " + absolutePath;
            } catch (e) {
                return "ERROR: Failed to set wallpaper: " + e.toString();
            }
        }

        function clear(): string {
            root.setWallpaper("");
            root.setPerMonitorWallpaper(false);
            root.monitorWallpapers = {};
            root.saveSettings();
            return "SUCCESS: All wallpapers cleared";
        }

        function next(): string {
            if (root.perMonitorWallpaper) {
                return "ERROR: Per-monitor mode enabled. Use nextFor(screenName) instead.";
            }

            if (!root.wallpaperPath) {
                return "ERROR: No wallpaper set";
            }

            try {
                WallpaperCyclingService.cycleNextManually();
                return "SUCCESS: Cycling to next wallpaper";
            } catch (e) {
                return "ERROR: Failed to cycle wallpaper: " + e.toString();
            }
        }

        function prev(): string {
            if (root.perMonitorWallpaper) {
                return "ERROR: Per-monitor mode enabled. Use prevFor(screenName) instead.";
            }

            if (!root.wallpaperPath) {
                return "ERROR: No wallpaper set";
            }

            try {
                WallpaperCyclingService.cyclePrevManually();
                return "SUCCESS: Cycling to previous wallpaper";
            } catch (e) {
                return "ERROR: Failed to cycle wallpaper: " + e.toString();
            }
        }

        function getFor(screenName: string): string {
            if (!screenName) {
                return "ERROR: No screen name provided";
            }
            return root.getMonitorWallpaper(screenName) || "";
        }

        function setFor(screenName: string, path: string): string {
            if (!screenName) {
                return "ERROR: No screen name provided";
            }

            if (!path) {
                return "ERROR: No path provided";
            }

            var absolutePath = path.startsWith("/") ? path : StandardPaths.writableLocation(StandardPaths.HomeLocation) + "/" + path;

            try {
                if (!root.perMonitorWallpaper) {
                    root.setPerMonitorWallpaper(true);
                }
                root.setMonitorWallpaper(screenName, absolutePath);
                return "SUCCESS: Wallpaper set for " + screenName + " to " + absolutePath;
            } catch (e) {
                return "ERROR: Failed to set wallpaper for " + screenName + ": " + e.toString();
            }
        }

        function nextFor(screenName: string): string {
            if (!screenName) {
                return "ERROR: No screen name provided";
            }

            var currentWallpaper = root.getMonitorWallpaper(screenName);
            if (!currentWallpaper) {
                return "ERROR: No wallpaper set for " + screenName;
            }

            try {
                WallpaperCyclingService.cycleNextForMonitor(screenName);
                return "SUCCESS: Cycling to next wallpaper for " + screenName;
            } catch (e) {
                return "ERROR: Failed to cycle wallpaper for " + screenName + ": " + e.toString();
            }
        }

        function prevFor(screenName: string): string {
            if (!screenName) {
                return "ERROR: No screen name provided";
            }

            var currentWallpaper = root.getMonitorWallpaper(screenName);
            if (!currentWallpaper) {
                return "ERROR: No wallpaper set for " + screenName;
            }

            try {
                WallpaperCyclingService.cyclePrevForMonitor(screenName);
                return "SUCCESS: Cycling to previous wallpaper for " + screenName;
            } catch (e) {
                return "ERROR: Failed to cycle wallpaper for " + screenName + ": " + e.toString();
            }
        }
    }
}
