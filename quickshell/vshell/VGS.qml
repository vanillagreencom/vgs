import QtQuick
import Quickshell
import qs.Common
import qs.Modals
import qs.Modals.Changelog
import qs.Modals.CloudSync
import qs.Modals.Clipboard
import qs.Modals.Capture
import qs.Modals.Common
import qs.Modals.Settings
import qs.Modals.Switcher
import qs.Modules
import qs.Modules.Dash
import qs.Modules.ControlCenter
import qs.Modules.Dock
import qs.Modules.Lock
import qs.Modules.Notepad
import qs.Modules.Notifications.Center
import qs.Widgets
import qs.Modules.Notifications.Popup
import qs.Modules.OSD
import qs.Modules.ProcessList
import qs.Modules.NetworkUsage
import qs.Modules.Bar
import qs.Modules.Bar.Popouts
import qs.Modules.WorkspaceOverlays
import qs.Modules.Settings.DisplayConfig
import qs.Services

Item {
    id: root
    readonly property var log: Log.scoped("VGS")
    readonly property var _sessionsServiceRef: SessionsService
    // Materialize the shipped default theme on a genuinely fresh install.
    // Without an eager reference this singleton was only constructed after
    // opening theme-related UI, leaving MethodTheme on its fallback palette.
    readonly property var _themeServiceRef: VGSThemeService
    // Same defect, same fix (VGS-82). ScratchpadService owns the focus-loss
    // watcher, and every other reference to it is in Settings — so without this
    // the watcher was only constructed once the user opened the Scratchpads
    // page, and `dismissOnFocusLoss` did nothing in any session where they did
    // not. A setting that works only after visiting Settings is the same
    // silently-inert surface the control was withheld for in the first place.
    readonly property var _scratchpadServiceRef: ScratchpadService

    property bool osdSurfacesLoaded: true
    property int pendingOsdResumeReloads: 0

    function recreateOsdSurfaces() {
        OSDManager.currentOSDsByScreen = ({});
        osdSurfacesLoaded = false;
        osdSurfaceReloadTimer.restart();
    }

    function showSwitchUserModal() {
        switchUserModalLoader.active = true;
        Qt.callLater(() => {
            if (switchUserModalLoader.item)
                switchUserModalLoader.item.showFromPowerMenu();
        });
    }

    Instantiator {
        id: daemonPluginInstantiator
        asynchronous: true
        model: Object.keys(PluginService.pluginDaemonComponents)

        delegate: Loader {
            id: daemonLoader
            property string pluginId: modelData
            // Kept so teardown can unregister by identity: `item` is not
            // reliable during destruction, and a reload's late teardown must
            // not clear the replacement delegate's registration.
            property var registeredInstance: null
            sourceComponent: PluginService.pluginDaemonComponents[pluginId]

            onLoaded: {
                if (item) {
                    item.pluginService = PluginService;
                    if (item.popoutService !== undefined) {
                        item.popoutService = PopoutService;
                    }
                    item.pluginId = pluginId;
                    daemonLoader.registeredInstance = item;
                    PluginService.registerDaemonInstance(pluginId, item);
                    log.info("Daemon plugin loaded:", pluginId);
                }
            }

            Component.onDestruction: PluginService.unregisterDaemonInstance(pluginId, daemonLoader.registeredInstance)
        }
    }

    Loader {
        id: blurredWallpaperBackgroundLoader
        active: SettingsData.blurredWallpaperLayer && CompositorService.isNiri
        asynchronous: false

        sourceComponent: BlurredWallpaperBackground {}
    }

    WallpaperBackground {}

    DesktopWidgetLayer {}

    // Native video screensaver overlays (one per screen). Loaded only while
    // ScreensaverService says the video saver is active.
    Variants {
        model: SettingsData.usableScreens()

        delegate: Loader {
            id: screensaverWindowLoader
            required property var modelData
            active: ScreensaverService.videoActive
            asynchronous: false

            sourceComponent: ScreensaverVideoWindow {
                screen: screensaverWindowLoader.modelData
            }
        }
    }

    Variants {
        model: SettingsData.usableScreens()

        delegate: Loader {
            id: fadeWindowLoader
            required property var modelData
            active: SettingsData.fadeToLockEnabled
            asynchronous: false

            sourceComponent: FadeToLockWindow {
                screen: fadeWindowLoader.modelData

                onFadeCompleted: {
                    IdleService.lockRequested();
                }

                onFadeCancelled: {
                    log.debug("Fade to lock cancelled by user on screen:", fadeWindowLoader.modelData.name);
                }
            }

            Connections {
                target: IdleService
                enabled: fadeWindowLoader.item !== null

                function onFadeToLockRequested() {
                    if (fadeWindowLoader.item) {
                        fadeWindowLoader.item.startFade();
                    }
                }

                function onCancelFadeToLock() {
                    if (fadeWindowLoader.item) {
                        fadeWindowLoader.item.cancelFade();
                    }
                }

                function onDismissFadeToLock() {
                    if (fadeWindowLoader.item) {
                        fadeWindowLoader.item.dismiss();
                    }
                }
            }
        }
    }

    Variants {
        model: SettingsData.usableScreens()

        delegate: Loader {
            id: fadeDpmsWindowLoader
            required property var modelData
            active: SettingsData.fadeToDpmsEnabled
            asynchronous: false

            sourceComponent: FadeToDpmsWindow {
                screen: fadeDpmsWindowLoader.modelData

                onFadeCompleted: {
                    IdleService.requestMonitorOff();
                }

                onFadeCancelled: {
                    log.debug("Fade to DPMS cancelled by user on screen:", fadeDpmsWindowLoader.modelData.name);
                }
            }

            Connections {
                target: IdleService
                enabled: fadeDpmsWindowLoader.item !== null

                function onFadeToDpmsRequested() {
                    if (fadeDpmsWindowLoader.item) {
                        fadeDpmsWindowLoader.item.startFade();
                    }
                }

                function onCancelFadeToDpms() {
                    if (fadeDpmsWindowLoader.item) {
                        fadeDpmsWindowLoader.item.cancelFade();
                    }
                }

                function onRequestMonitorOn() {
                    if (!fadeDpmsWindowLoader.item)
                        return;
                    fadeDpmsWindowLoader.item.cancelFade();
                }
            }
        }
    }

    property bool barSurfacesLoaded: true

    function recreateBarSurfaces() {
        log.info("Recreating bar surfaces, screens:", Quickshell.screens.length, Quickshell.screens.map(s => s.name).join(","));
        if (barSurfacesLoaded)
            barSurfacesLoaded = false;
        barSurfaceReloadAction.schedule();
    }

    DeferredAction {
        id: barSurfaceReloadAction
        onTriggered: root.barSurfacesLoaded = true
    }

    property string _barLayoutStateJson: {
        if (!barSurfacesLoaded)
            return "[]";
        const configs = SettingsData.barConfigs;
        const mapped = configs.map(c => ({
                    id: c.id,
                    position: c.position,
                    autoHide: c.autoHide,
                    visible: c.visible
                })).sort((a, b) => {
            const aVertical = a.position === SettingsData.Position.Left || a.position === SettingsData.Position.Right;
            const bVertical = b.position === SettingsData.Position.Left || b.position === SettingsData.Position.Right;
            if (aVertical !== bVertical) {
                return aVertical - bVertical;
            }
            return String(a.id).localeCompare(String(b.id));
        });
        return JSON.stringify(mapped);
    }

    on_BarLayoutStateJsonChanged: {
        if (typeof dockRecreateDebounce !== "undefined") {
            dockRecreateDebounce.restart();
        }
    }

    Connections {
        target: SettingsData
        function onForceBarLayoutRefresh() {
            root.recreateBarSurfaces();
        }
    }

    // UPower answers well after settings load, so a laptop only becomes a
    // laptop some way into startup. Reconcile the bar widget lists against the
    // hardware then — a barConfigs carried over from a desktop otherwise never
    // grows a battery indicator, because nothing revisits that array once the
    // user has one of their own.
    Connections {
        target: BatteryService
        function onBatteryAvailableChanged() {
            SettingsData.reconcileHardwareBarWidgets();
        }
    }

    Repeater {
        id: barRepeater
        model: ScriptModel {
            id: barRepeaterModel
            values: JSON.parse(root._barLayoutStateJson)
        }

        Component.onCompleted: BarWidgetService.barRepeater = barRepeater

        property var hyprlandOverviewLoaderRef: hyprlandOverviewLoader

        delegate: Loader {
            id: barLoader
            required property var modelData
            property var barConfig: SettingsData.barConfigs.find(cfg => cfg.id === modelData.id) || null
            active: root.barSurfacesLoaded && (barConfig?.enabled ?? false)
            asynchronous: false

            sourceComponent: Bar {
                barConfig: barLoader.barConfig
                hyprlandOverviewLoader: barRepeater.hyprlandOverviewLoaderRef

                onColorPickerRequested: {
                    if (colorPickerModal.shouldBeVisible) {
                        colorPickerModal.close();
                    } else {
                        colorPickerModal.show();
                    }
                }
            }
        }
    }

    property bool dockEnabled: false

    Timer {
        id: dockRecreateDebounce
        interval: 500
        repeat: false
        onTriggered: {
            root.dockEnabled = false;
            Qt.callLater(() => {
                root.dockEnabled = true;
            });
        }
    }

    Timer {
        id: loginSoundTimer
        // Half a second delay before playing login sound, otherwise the sound may be cut off
        // 50 is the minimum that seems to work, but 500 is safer
        interval: 500
        repeat: false
        onTriggered: {
            AudioService.playLoginSoundIfApplicable();
        }
    }

    Timer {
        id: osdResumeRecreateTimer
        interval: 400
        repeat: false
        onTriggered: {
            root.recreateOsdSurfaces();
            root.pendingOsdResumeReloads--;

            if (root.pendingOsdResumeReloads <= 0) {
                root.pendingOsdResumeReloads = 0;
                interval = 400;
                return;
            }

            interval = 1400;
            restart();
        }
    }

    Timer {
        id: osdSurfaceReloadTimer
        interval: 120
        repeat: false
        onTriggered: root.osdSurfacesLoaded = true
    }

    property bool hadRealScreen: true
    property var previousRealScreenNames: []
    // Guards for the screen-reconnect recovery path (see scheduleScreenReconnectRecovery).
    property bool _screenRecoveryCooldown: false
    property bool _screenRecoveryPending: false

    function _getRealScreenNames() {
        const names = [];
        for (let i = 0; i < Quickshell.screens.length; i++) {
            if (Quickshell.screens[i].name.length > 0)
                names.push(Quickshell.screens[i].name);
        }
        return names;
    }

    function _hasRealScreen() {
        for (let i = 0; i < Quickshell.screens.length; i++) {
            if (Quickshell.screens[i].name.length > 0)
                return true;
        }
        return false;
    }

    function triggerSurfaceRecovery(source) {
        log.info("Surface recovery triggered by:", source, "screens:", Quickshell.screens.length, Quickshell.screens.map(s => s.name).join(","), "barLoaded:", root.barSurfacesLoaded, "dockEnabled:", root.dockEnabled);
        surfaceResumeRecoveryTimer.pass = 0;
        surfaceResumeRecoveryTimer.interval = 800;
        surfaceResumeRecoveryTimer.restart();
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            const hasReal = root._hasRealScreen();
            const currentNames = root._getRealScreenNames();
            log.info("Screens changed:", Quickshell.screens.length, Quickshell.screens.map(s => "'" + s.name + "'").join(","), "hasReal:", hasReal, "hadReal:", root.hadRealScreen);
            const fullReconnect = !root.hadRealScreen && hasReal;
            const partialReconnect = root.previousRealScreenNames.length > 0 && currentNames.some(name => !root.previousRealScreenNames.includes(name));
            if (fullReconnect || partialReconnect) {
                log.info("Screen reconnect detected, scheduling surface recovery", "full:", fullReconnect, "partial:", partialReconnect);
                root.scheduleScreenReconnectRecovery();
            }
            root.hadRealScreen = hasReal;
            root.previousRealScreenNames = currentNames;
        }
    }

    // A DPMS off/on cycle removes an output from the screen list and re-adds it,
    // which is indistinguishable here from a hotplug. Recovering immediately on
    // every such event lets a flapping monitor (or a recovery that itself perturbs
    // the output) drive an endless recovery storm that power-cycles the display
    // (#2642). Debounce a burst of changes into a single pass, then hold a cooldown
    // so repeated flaps trigger at most one recovery per window. Recovery still runs
    // once per resume, so a partial DPMS resume keeps redrawing its surfaces (#2579).
    function scheduleScreenReconnectRecovery() {
        if (root._screenRecoveryCooldown) {
            root._screenRecoveryPending = true;
            return;
        }
        screenReconnectDebounce.restart();
    }

    Timer {
        id: screenReconnectDebounce
        // Wide enough to collapse the output-remove + output-re-add pair that one
        // DPMS off/on cycle emits as two near-simultaneous events into one recovery.
        interval: 450
        repeat: false
        onTriggered: {
            root._screenRecoveryCooldown = true;
            root._screenRecoveryPending = false;
            screenReconnectCooldown.restart();
            root.triggerSurfaceRecovery("screen-reconnect");
        }
    }

    Timer {
        id: screenReconnectCooldown
        // Must exceed the full two-pass surfaceResumeRecoveryTimer sequence
        // (800 + 2000 ms) so the cooldown still covers an in-flight recovery;
        // raise this if those passes are lengthened.
        interval: 4000
        repeat: false
        onTriggered: {
            root._screenRecoveryCooldown = false;
            if (root._screenRecoveryPending) {
                root._screenRecoveryPending = false;
                screenReconnectDebounce.restart();
            }
        }
    }

    Timer {
        id: surfaceResumeRecoveryTimer
        interval: 800
        repeat: false
        property int pass: 0
        onTriggered: {
            pass++;
            log.info("Surface recovery pass", pass, "screens:", Quickshell.screens.length, Quickshell.screens.map(s => s.name).join(","));

            root.recreateBarSurfaces();

            root.dockEnabled = false;
            Qt.callLater(() => {
                root.dockEnabled = true;
            });

            if (pass < 2) {
                interval = 2000;
                restart();
            } else {
                pass = 0;
                interval = 800;
            }
        }
    }

    Component.onCompleted: {
        dockRecreateDebounce.start();
        loginSoundTimer.start();

        // These are dummy references just to trigger the singletons onCompleted to trigger
        PolkitService.polkitAvailable;
        DisplayConfigState.hasOutputBackend;
        PortalService.systemColorScheme;
    }

    Loader {
        id: dockLoader
        active: root.dockEnabled
        asynchronous: false

        property var currentPosition: SettingsData.dockPosition
        property bool initialized: false

        sourceComponent: Dock {
            contextMenu: dockContextMenuLoader.item ? dockContextMenuLoader.item : null
            trashContextMenu: dockTrashContextMenuLoader.item ? dockTrashContextMenuLoader.item : null
        }

        onLoaded: {
            if (item) {
                dockContextMenuLoader.active = true;
                if (SettingsData.dockShowTrash) {
                    dockTrashContextMenuLoader.active = true;
                }
            }
        }

        Component.onCompleted: {
            initialized = true;
        }

        onCurrentPositionChanged: {
            if (!initialized)
                return;
            const comp = sourceComponent;
            sourceComponent = null;
            sourceComponent = comp;
        }
    }

    Loader {
        id: dashPopoutLoader

        active: false
        asynchronous: false

        Component.onCompleted: {
            PopoutService.dashPopoutLoader = dashPopoutLoader;
        }

        onLoaded: {
            if (item) {
                PopoutService.dashPopout = item;
                PopoutService._onDashPopoutLoaded();
            }
        }

        sourceComponent: Component {
            DashPopout {
                id: dashPopout
            }
        }
    }

    LazyLoader {
        id: dockContextMenuLoader

        active: false

        DockContextMenu {
            id: dockContextMenu
        }
    }

    LazyLoader {
        id: dockTrashContextMenuLoader

        active: false

        DockTrashContextMenu {
            id: dockTrashContextMenu
        }
    }

    Connections {
        target: SettingsData
        function onDockShowTrashChanged() {
            if (SettingsData.dockShowTrash) {
                dockTrashContextMenuLoader.active = true;
            }
        }
    }

    ConfirmModal {
        id: emptyTrashConfirm
    }

    Connections {
        target: TrashService
        function onEmptyTrashConfirmRequested(itemCount) {
            emptyTrashConfirm.showWithOptions({
                title: I18n.tr("Empty Trash?"),
                message: I18n.tr("Permanently delete %1 item(s)? This cannot be undone.").arg(itemCount),
                confirmText: I18n.tr("Empty"),
                cancelText: I18n.tr("Cancel"),
                confirmColor: Theme.error,
                onConfirm: () => TrashService.emptyTrash()
            });
        }
    }

    LazyLoader {
        id: notificationCenterLoader

        active: false

        Component.onCompleted: {
            PopoutService.notificationCenterLoader = notificationCenterLoader;
        }

        NotificationCenterPopout {
            id: notificationCenter
            onPopoutClosed: PopoutService.unloadNotificationCenter()

            Component.onCompleted: {
                PopoutService.notificationCenterPopout = notificationCenter;
            }
        }
    }

    Variants {
        model: SettingsData.notificationFocusedMonitor ? SettingsData.usableScreens() : SettingsData.getFilteredScreens("notifications")

        delegate: NotificationPopupManager {
            modelData: item
        }
    }

    LazyLoader {
        id: controlCenterLoader

        active: false

        property var modalRef: colorPickerModal
        property LazyLoader powerModalLoaderRef: powerMenuModalLoader

        Component.onCompleted: {
            PopoutService.controlCenterLoader = controlCenterLoader;
        }

        ControlCenterPopout {
            id: controlCenterPopout
            colorPickerModal: controlCenterLoader.modalRef
            powerMenuModalLoader: controlCenterLoader.powerModalLoaderRef
            onPopoutClosed: PopoutService.unloadControlCenter()

            onLockRequested: {
                IdleService.requestLock("control center");
            }

            onSwitchUserRequested: root.showSwitchUserModal()

            Component.onCompleted: {
                PopoutService.controlCenterPopout = controlCenterPopout;
            }
        }
    }

    LazyLoader {
        id: wifiPasswordModalLoader
        active: false

        Component.onCompleted: {
            PopoutService.wifiPasswordModalLoader = wifiPasswordModalLoader;
        }

        WifiPasswordModal {
            id: wifiPasswordModalItem

            Component.onCompleted: {
                PopoutService.wifiPasswordModal = wifiPasswordModalItem;
            }
        }
    }

    LazyLoader {
        id: wifiQRCodeModalLoader
        active: false

        Component.onCompleted: {
            PopoutService.wifiQRCodeModalLoader = wifiQRCodeModalLoader;
        }

        WifiQRCodeModal {
            id: wifiQRCodeModalItem

            Component.onCompleted: {
                PopoutService.wifiQRCodeModal = wifiQRCodeModalItem;
            }
        }
    }

    LazyLoader {
        id: polkitAuthModalLoader
        active: false

        PolkitAuthModal {
            id: polkitAuthModal

            Component.onCompleted: {
                PopoutService.polkitAuthModal = polkitAuthModal;
            }
        }
    }

    Connections {
        target: PolkitService.agent
        enabled: PolkitService.polkitAvailable

        function onAuthenticationRequestStarted() {
            polkitAuthModalLoader.active = true;
            if (polkitAuthModalLoader.item)
                polkitAuthModalLoader.item.show();
        }
    }

    BluetoothPairingModal {
        id: bluetoothPairingModal

        Component.onCompleted: {
            PopoutService.bluetoothPairingModal = bluetoothPairingModal;
        }
    }

    property string lastCredentialsToken: ""
    property var lastCredentialsTime: 0

    Connections {
        target: NetworkService

        function onCredentialsNeeded(token, ssid, setting, fields, hints, reason, connType, connName, vpnService, fieldsInfo) {
            const alreadyShown = wifiPasswordModalLoader.item && wifiPasswordModalLoader.item.shouldBeVisible;
            if (alreadyShown && token === lastCredentialsToken)
                return;

            wifiPasswordModalLoader.active = true;
            if (!wifiPasswordModalLoader.item)
                return;

            if (alreadyShown && lastCredentialsToken !== "" && lastCredentialsToken !== token)
                NetworkService.cancelCredentials(lastCredentialsToken);

            lastCredentialsToken = token;
            lastCredentialsTime = Date.now();
            wifiPasswordModalLoader.item.showFromPrompt(token, ssid, setting, fields, hints, reason, connType, connName, vpnService, fieldsInfo);
        }
    }

    LazyLoader {
        id: networkInfoModalLoader

        active: false

        NetworkInfoModal {
            id: networkInfoModal

            Component.onCompleted: {
                PopoutService.networkInfoModal = networkInfoModal;
            }
        }
    }

    LazyLoader {
        id: batteryPopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.batteryPopoutLoader = batteryPopoutLoader;
        }

        BatteryPopout {
            id: batteryPopout
            onPopoutClosed: PopoutService.unloadBattery()

            Component.onCompleted: {
                PopoutService.batteryPopout = batteryPopout;
            }
        }
    }

    LazyLoader {
        id: layoutPopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.layoutPopoutLoader = layoutPopoutLoader;
        }

        DWLLayoutPopout {
            id: layoutPopout
            onPopoutClosed: PopoutService.unloadLayoutPopout()

            Component.onCompleted: {
                PopoutService.layoutPopout = layoutPopout;
            }
        }
    }

    LazyLoader {
        id: vpnPopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.vpnPopoutLoader = vpnPopoutLoader;
        }

        VpnPopout {
            id: vpnPopout
            onPopoutClosed: PopoutService.unloadVpn()

            Component.onCompleted: {
                PopoutService.vpnPopout = vpnPopout;
            }
        }
    }

    LazyLoader {
        id: processListPopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.processListPopoutLoader = processListPopoutLoader;
        }

        ProcessListPopout {
            id: processListPopout
            onPopoutClosed: PopoutService.unloadProcessListPopout()

            Component.onCompleted: {
                PopoutService.processListPopout = processListPopout;
            }
        }
    }

    LazyLoader {
        id: networkUsagePopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.networkUsagePopoutLoader = networkUsagePopoutLoader;
        }

        NetworkUsagePopout {
            id: networkUsagePopout
            onPopoutClosed: PopoutService.unloadNetworkUsagePopout()

            Component.onCompleted: {
                PopoutService.networkUsagePopout = networkUsagePopout;
            }
        }
    }

    LazyLoader {
        id: settingsModalLoader

        active: false

        Component.onCompleted: {
            PopoutService.settingsModalLoader = settingsModalLoader;
        }

        onActiveChanged: {
            if (active && item) {
                PopoutService.settingsModal = item;
                PopoutService._onSettingsModalLoaded();
            }
        }

        SettingsModal {
            id: settingsModal
            property bool wasShown: false

            onVisibleChanged: {
                if (visible) {
                    wasShown = true;
                } else if (wasShown) {
                    PopoutService.unloadSettings();
                }
            }
        }
    }

    LazyLoader {
        id: cloudSyncModalLoader

        active: false

        Component.onCompleted: {
            PopoutService.cloudSyncModalLoader = cloudSyncModalLoader;
        }

        onActiveChanged: {
            if (active && item) {
                PopoutService.cloudSyncModal = item;
                PopoutService._onCloudSyncModalLoaded();
            }
        }

        CloudSyncModal {
            id: cloudSyncModal
            property bool wasShown: false

            onVisibleChanged: {
                if (visible) {
                    wasShown = true;
                } else if (wasShown) {
                    PopoutService.unloadCloudSync();
                }
            }
        }
    }

    LazyLoader {
        id: clipboardHistoryPopoutLoader

        active: false

        Component.onCompleted: {
            PopoutService.clipboardHistoryPopoutLoader = clipboardHistoryPopoutLoader;
        }

        ClipboardHistoryPopout {
            id: clipboardHistoryPopout
            onPopoutClosed: PopoutService.unloadClipboardHistoryPopout()

            Component.onCompleted: {
                PopoutService.clipboardHistoryPopout = clipboardHistoryPopout;
            }
        }
    }

    MuxModal {
        id: muxModal
    }

    ClipboardHistoryModal {
        id: clipboardHistoryModalPopup

        Component.onCompleted: {
            PopoutService.clipboardHistoryModal = clipboardHistoryModalPopup;
        }
    }

    NotificationModal {
        id: notificationModal

        Component.onCompleted: {
            PopoutService.notificationModal = notificationModal;
        }
    }

    BrowserPickerModal {
        id: browserPickerModal
    }

    AppPickerModal {
        id: filePickerModal
        title: I18n.tr("Open with...")
        viewMode: SettingsData.appPickerViewMode || "grid"

        onViewModeChanged: {
            SettingsData.set("appPickerViewMode", viewMode);
        }

        function shellEscape(str) {
            return "'" + str.replace(/'/g, "'\\''") + "'";
        }

        onApplicationSelected: (app, filePath) => {
            if (!app)
                return;
            let cmd = app.exec || "";
            const escapedPath = shellEscape(filePath);
            const escapedUri = shellEscape("file://" + filePath);

            let hasField = false;
            if (cmd.includes("%f")) {
                cmd = cmd.replace("%f", escapedPath);
                hasField = true;
            } else if (cmd.includes("%F")) {
                cmd = cmd.replace("%F", escapedPath);
                hasField = true;
            } else if (cmd.includes("%u")) {
                cmd = cmd.replace("%u", escapedUri);
                hasField = true;
            } else if (cmd.includes("%U")) {
                cmd = cmd.replace("%U", escapedUri);
                hasField = true;
            }

            cmd = cmd.replace(/%[ikc]/g, "");

            if (!hasField) {
                cmd += " " + escapedPath;
            }

            log.debug("FilePicker: Launching", cmd);

            Quickshell.execDetached({
                command: ["sh", "-c", cmd]
            });
        }
    }

    Connections {
        target: VGSBackendService
        function onOpenUrlRequested(url) {
            if (url.startsWith("vshell://theme/install/")) {
                var themeId = url.replace("vshell://theme/install/", "").split(/[?#]/)[0];
                if (themeId) {
                    PopoutService.pendingThemeInstall = themeId;
                    PopoutService.openSettingsWithTab("theme");
                }
                return;
            }
            if (url.startsWith("vshell://plugin/install/")) {
                var pluginId = url.replace("vshell://plugin/install/", "").split(/[?#]/)[0];
                if (pluginId) {
                    PopoutService.pendingPluginInstall = pluginId;
                    PopoutService.openSettingsWithTab("plugins");
                }
                return;
            }
            browserPickerModal.url = url;
            browserPickerModal.open();
        }

        function onAppPickerRequested(data) {
            log.debug("App picker requested with data:", JSON.stringify(data));

            if (!data || !data.target) {
                log.warn("Invalid app picker request data");
                return;
            }

            filePickerModal.targetData = data.target;
            filePickerModal.targetDataLabel = data.requestType || "file";
            filePickerModal.mimeType = data.mimeType || "";
            filePickerModal.rememberMimeTypes = [];

            if (data.categories && data.categories.length > 0) {
                filePickerModal.categoryFilter = data.categories;
            } else {
                filePickerModal.categoryFilter = [];
            }

            filePickerModal.usageHistoryKey = "filePickerUsageHistory";
            filePickerModal.open();
        }
    }

    Connections {
        target: SessionService

        function onSessionResumed() {
            log.info("Session resumed: screens:", Quickshell.screens.length, Quickshell.screens.map(s => s.name).join(","), "barLoaded:", root.barSurfacesLoaded, "dockEnabled:", root.dockEnabled);

            root.pendingOsdResumeReloads = 2;
            osdResumeRecreateTimer.interval = 400;
            osdResumeRecreateTimer.restart();

            // This path runs its own recovery directly, so drop any queued or
            // in-flight screen-reconnect recovery to avoid a redundant pass once
            // its cooldown expires.
            screenReconnectDebounce.stop();
            screenReconnectCooldown.stop();
            root._screenRecoveryCooldown = false;
            root._screenRecoveryPending = false;

            root.triggerSurfaceRecovery("sessionResumed");
        }
    }

    VgsColorPickerModal {
        id: colorPickerModal

        Component.onCompleted: {
            PopoutService.colorPickerModal = colorPickerModal;
        }
    }

    LazyLoader {
        id: workspaceRenameModalLoader

        active: false

        Component.onCompleted: PopoutService.workspaceRenameModalLoader = workspaceRenameModalLoader

        WorkspaceRenameModal {
            id: workspaceRenameModal
        }
    }

    LazyLoader {
        id: windowRuleModalLoader

        active: false

        Component.onCompleted: PopoutService.windowRuleModalLoader = windowRuleModalLoader

        WindowRuleModal {
            id: windowRuleModal
        }
    }

    LazyLoader {
        id: processListModalLoader

        active: false

        Component.onCompleted: PopoutService.processListModalLoader = processListModalLoader

        ProcessListModal {
            id: processListModal
            property bool wasShown: false

            Component.onCompleted: {
                PopoutService.processListModal = processListModal;
            }

            onVisibleChanged: {
                if (visible) {
                    wasShown = true;
                } else if (wasShown) {
                    PopoutService.unloadProcessListModal();
                }
            }
        }
    }

    Variants {
        id: notepadSlideoutVariants
        model: SettingsData.getFilteredScreens("notepad")

        delegate: VgsSlideout {
            id: notepadSlideout
            modelData: item
            title: I18n.tr("Notepad")
            slideoutWidth: 480
            expandable: true
            expandedWidthValue: 960
            edgeGap: SettingsData.notepadEffectiveEdgeGap
            slideEdge: SettingsData.notepadSlideoutSide

            onIsVisibleChanged: {
                if (isVisible)
                    PopoutService.notepadPopout?.hide();
            }

            content: Component {
                Notepad {
                    slideout: notepadSlideout
                    onHideRequested: notepadSlideout.hide()
                    onPopoutRequested: {
                        notepadSlideout.hide();
                        PopoutService.openNotepadPopout();
                    }
                }
            }

            function toggle() {
                if (isVisible) {
                    hide();
                } else {
                    show();
                }
            }
        }

        onInstancesChanged: PopoutService.notepadSlideouts = instances
        Component.onCompleted: PopoutService.notepadSlideouts = instances
    }

    LazyLoader {
        id: notepadPopoutLoader
        active: false

        Component.onCompleted: {
            PopoutService.notepadPopoutLoader = notepadPopoutLoader;
        }

        onActiveChanged: {
            if (active && item) {
                PopoutService.notepadPopout = item;
                PopoutService._onNotepadPopoutLoaded();
            }
        }

        NotepadPopoutWindow {}
    }

    LazyLoader {
        id: captureModalLoader

        active: false
        property string requestedAction: ""
        property string requestedScreenName: ""

        function request(action, screenName) {
            // Closing while unloaded would instantiate the modal just to close
            // it; report that nothing was open instead.
            if (action === "close" && !active)
                return false;
            requestedAction = action;
            requestedScreenName = screenName || "";
            active = true;
            flushRequest();
            return true;
        }

        function flushRequest() {
            if (!item || requestedAction === "")
                return;
            const action = requestedAction;
            const screenName = requestedScreenName;
            requestedAction = "";
            requestedScreenName = "";
            if (action === "close")
                item.close();
            else if (action === "toggle")
                item.toggleChooser();
            else {
                const target = screenName ? (Quickshell.screens.find(screen => screen.name === screenName) || null) : null;
                item.showOnScreen(target);
            }
        }

        onItemChanged: flushRequest()

        CaptureModal {
            id: captureModal
        }
    }

    LazyLoader {
        id: powerMenuModalLoader

        active: false

        PowerMenuModal {
            id: powerMenuModal

            onPowerActionRequested: (action, title, message) => {
                PopoutService.closeControlCenter();
                switch (action) {
                case "logout":
                    SessionService.logout();
                    break;
                case "suspend":
                    SessionService.suspend();
                    break;
                case "hibernate":
                    SessionService.hibernate();
                    break;
                case "reboot":
                    SessionService.reboot();
                    break;
                case "poweroff":
                    SessionService.poweroff();
                    break;
                }
            }

            onLockRequested: {
                PopoutService.closeControlCenter();
                IdleService.requestLock("power menu");
            }

            onSwitchUserRequested: root.showSwitchUserModal()

            Component.onCompleted: {
                PopoutService.powerMenuModal = powerMenuModal;
            }
        }
    }

    Connections {
        target: SessionsService

        function onSwitchRequested() {
            root.showSwitchUserModal();
        }
    }

    LazyLoader {
        id: switchUserModalLoader

        active: false

        SwitchUserModal {
            id: switchUserModal
        }
    }

    LazyLoader {
        id: hyprKeybindsModalLoader

        active: false

        KeybindsModal {
            id: keybindsModal

            Component.onCompleted: {
                PopoutService.hyprKeybindsModal = keybindsModal;
            }
        }
    }

    LazyLoader {
        id: powerProfileModalLoader

        active: false

        PowerProfileModal {
            id: powerProfileModal

            Component.onCompleted: {
                PopoutService.powerProfileModal = powerProfileModal;
            }
        }

        Component.onCompleted: {
            PopoutService.powerProfileModalLoader = powerProfileModalLoader;
        }
    }

    WallpaperSwitcherModal {
        id: wallpaperSwitcherModal
    }

    ThemeSwitcherModal {
        id: themeSwitcherModal
    }

    VGSIPC {
        captureModalLoader: captureModalLoader
        powerMenuModalLoader: powerMenuModalLoader
        processListModalLoader: processListModalLoader
        controlCenterLoader: controlCenterLoader
        dashPopoutLoader: dashPopoutLoader
        notepadSlideoutVariants: notepadSlideoutVariants
        hyprKeybindsModalLoader: hyprKeybindsModalLoader
        barRepeater: barRepeater
        hyprlandOverviewLoader: hyprlandOverviewLoader
        workspaceRenameModalLoader: workspaceRenameModalLoader
        windowRuleModalLoader: windowRuleModalLoader
        browserPickerModal: browserPickerModal
        appPickerModal: filePickerModal
        changelogLoader: changelogLoader
        wallpaperSwitcherModal: wallpaperSwitcherModal
        themeSwitcherModal: themeSwitcherModal
    }

    Variants {
        model: SettingsData.getFilteredScreens("toast")

        delegate: Toast {
            modelData: item
            visible: ToastService.toastVisible
        }
    }

    Loader {
        id: osdSurfacesLoader
        active: root.osdSurfacesLoaded
        asynchronous: false

        sourceComponent: Component {
            Item {
                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: VolumeOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: MediaVolumeOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: MediaPlaybackOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: MicVolumeOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: BrightnessOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: IdleInhibitorOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.osdPowerProfileEnabled ? SettingsData.getFilteredScreens("osd") : []

                    delegate: PowerProfileOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: CapsLockOSD {
                        modelData: item
                    }
                }

                Variants {
                    model: SettingsData.getFilteredScreens("osd")

                    delegate: AudioOutputOSD {
                        modelData: item
                    }
                }
            }
        }
    }

    LazyLoader {
        id: hyprlandOverviewLoader
        active: CompositorService.isHyprland
        component: HyprlandOverview {
            id: hyprlandOverview
        }
    }

    LazyLoader {
        id: niriOverviewOverlayLoader
        active: CompositorService.isNiri && SettingsData.niriOverviewOverlayEnabled
        component: NiriOverviewOverlay {
            id: niriOverviewOverlay
        }
    }

    // Desktop shell loader only. Login greeter runs from VGSGreeter through VSHELL_RUN_GREETER.

    Loader {
        id: changelogLoader
        active: false
        sourceComponent: ChangelogModal {
            onChangelogDismissed: changelogLoader.active = false
            Component.onCompleted: show()
        }

        Connections {
            target: ChangelogService
            function onChangelogRequested() {
                if (changelogLoader.active && changelogLoader.item) {
                    changelogLoader.item.show();
                    return;
                }
                changelogLoader.active = true;
            }
        }
    }
}
