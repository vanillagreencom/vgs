pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common

Singleton {
    id: root

    property var controlCenterPopout: null
    property var controlCenterLoader: null
    property var notificationCenterPopout: null
    property var notificationCenterLoader: null
    property var processListPopout: null
    property var processListPopoutLoader: null
    property var networkUsagePopout: null
    property var networkUsagePopoutLoader: null
    property var dashPopout: null
    property var dashPopoutLoader: null
    property var batteryPopout: null
    property var batteryPopoutLoader: null
    property var vpnPopout: null
    property var vpnPopoutLoader: null
    property var layoutPopout: null
    property var layoutPopoutLoader: null
    property var clipboardHistoryPopout: null
    property var clipboardHistoryPopoutLoader: null

    property var settingsModal: null
    property var settingsModalLoader: null
    property var cloudSyncModal: null
    property var cloudSyncModalLoader: null
    property var clipboardHistoryModal: null
    property var powerMenuModal: null
    property var processListModal: null
    property var processListModalLoader: null
    property var colorPickerModal: null
    property var notificationModal: null
    property var wifiPasswordModal: null
    property var wifiPasswordModalLoader: null
    property var wifiQRCodeModal: null
    property var wifiQRCodeModalLoader: null
    property var polkitAuthModal: null
    property var polkitAuthModalLoader: null
    property var bluetoothPairingModal: null
    property var networkInfoModal: null
    property var windowRuleModalLoader: null
    property var powerProfileModal: null
    property var powerProfileModalLoader: null

    property var notepadSlideouts: []

    property string pendingThemeInstall: ""
    property string pendingPluginInstall: ""

    // Deferred unload: keep popouts warm while the session is active and reclaim them on lock/monitors-off.
    property var _pendingUnloads: ({})

    Connections {
        target: SessionService
        function onSessionLocked() {
            root._flushPendingUnloads();
        }
    }

    Connections {
        target: IdleService
        function onMonitorsOffChanged() {
            if (IdleService.monitorsOff)
                root._flushPendingUnloads();
        }
    }

    function _scheduleUnload(key) {
        _pendingUnloads[key] = true;
    }

    function _flushPendingUnloads() {
        const keys = Object.keys(_pendingUnloads);
        _pendingUnloads = ({});
        for (let i = 0; i < keys.length; i++) {
            const unload = _deferredUnloaders[keys[i]];
            if (unload)
                unload();
        }
    }

    function _popoutStillPresented(popout) {
        return !!popout && (popout.shouldBeVisible === true || popout.isClosing === true);
    }

    function _unloadPopoutNow(popoutName, loaderName) {
        const loader = root[loaderName];
        if (!loader)
            return;
        if (_popoutStillPresented(root[popoutName]))
            return;
        root[popoutName] = null;
        loader.active = false;
    }

    readonly property var _deferredUnloaders: ({
            "controlCenter": () => _unloadPopoutNow("controlCenterPopout", "controlCenterLoader"),
            "notificationCenter": () => _unloadPopoutNow("notificationCenterPopout", "notificationCenterLoader"),
            "processList": () => _unloadPopoutNow("processListPopout", "processListPopoutLoader"),
            "networkUsage": () => _unloadPopoutNow("networkUsagePopout", "networkUsagePopoutLoader"),
            "battery": () => _unloadPopoutNow("batteryPopout", "batteryPopoutLoader"),
            "vpn": () => _unloadPopoutNow("vpnPopout", "vpnPopoutLoader"),
            "layout": () => _unloadPopoutNow("layoutPopout", "layoutPopoutLoader"),
            "clipboardHistory": () => _unloadPopoutNow("clipboardHistoryPopout", "clipboardHistoryPopoutLoader"),
            "settings": () => _unloadSettingsNow(),
            "cloudSync": () => _unloadCloudSyncNow()
        })

    function setPosition(popout, x, y, width, section, screen) {
        if (popout && popout.setTriggerPosition && arguments.length >= 6) {
            popout.setTriggerPosition(x, y, width, section, screen);
        }
    }

    function openControlCenter(x, y, width, section, screen) {
        if (controlCenterPopout) {
            setPosition(controlCenterPopout, x, y, width, section, screen);
            controlCenterPopout.open();
        }
    }

    function closeControlCenter() {
        controlCenterPopout?.close();
    }

    function unloadControlCenter() {
        _scheduleUnload("controlCenter");
    }

    function toggleControlCenter(x, y, width, section, screen) {
        if (controlCenterPopout) {
            setPosition(controlCenterPopout, x, y, width, section, screen);
            controlCenterPopout.toggle();
        }
    }

    function openNotificationCenter(x, y, width, section, screen) {
        if (notificationCenterPopout) {
            setPosition(notificationCenterPopout, x, y, width, section, screen);
            notificationCenterPopout.open();
        }
    }

    function closeNotificationCenter() {
        notificationCenterPopout?.close();
    }

    function unloadNotificationCenter() {
        _scheduleUnload("notificationCenter");
    }

    function toggleNotificationCenter(x, y, width, section, screen) {
        if (notificationCenterPopout) {
            setPosition(notificationCenterPopout, x, y, width, section, screen);
            notificationCenterPopout.toggle();
        }
    }

    function openProcessList(x, y, width, section, screen) {
        if (processListPopout) {
            setPosition(processListPopout, x, y, width, section, screen);
            processListPopout.open();
        }
    }

    function closeProcessList() {
        processListPopout?.close();
    }

    function unloadProcessListPopout() {
        _scheduleUnload("processList");
    }

    function unloadNetworkUsagePopout() {
        _scheduleUnload("networkUsage");
    }

    function toggleProcessList(x, y, width, section, screen) {
        if (processListPopout) {
            setPosition(processListPopout, x, y, width, section, screen);
            processListPopout.toggle();
        }
    }

    property bool _dashWantsOpen: false
    property bool _dashWantsToggle: false
    property int _dashPendingTab: 0
    property real _dashPendingX: 0
    property real _dashPendingY: 0
    property real _dashPendingWidth: 0
    property string _dashPendingSection: ""
    property var _dashPendingScreen: null
    property bool _dashHasPosition: false

    function _storeDashPosition(x, y, width, section, screen, hasPos) {
        _dashPendingX = x;
        _dashPendingY = y;
        _dashPendingWidth = width;
        _dashPendingSection = section;
        _dashPendingScreen = screen;
        _dashHasPosition = hasPos;
    }

    function openDash(tabIndex, x, y, width, section, screen) {
        _dashPendingTab = tabIndex || 0;
        if (dashPopout) {
            if (arguments.length >= 6)
                setPosition(dashPopout, x, y, width, section, screen);
            dashPopout.currentTabIndex = _dashPendingTab;
            dashPopout.dashVisible = true;
            return;
        }
        if (!dashPopoutLoader)
            return;
        _storeDashPosition(x, y, width, section, screen, arguments.length >= 6);
        _dashWantsOpen = true;
        _dashWantsToggle = false;
        dashPopoutLoader.active = true;
    }

    function closeDash() {
        if (dashPopout)
            dashPopout.dashVisible = false;
    }

    function unloadDash() {
        // Dash is intentionally kept alive after first use. Destroying this
        // lazy popout during its close signal can invalidate surface bindings
        // while Qt is still unwinding the signal stack.
    }

    function toggleDash(tabIndex, x, y, width, section, screen) {
        _dashPendingTab = tabIndex || 0;
        if (dashPopout) {
            if (arguments.length >= 6)
                setPosition(dashPopout, x, y, width, section, screen);
            if (dashPopout.dashVisible) {
                dashPopout.dashVisible = false;
            } else {
                dashPopout.currentTabIndex = _dashPendingTab;
                dashPopout.dashVisible = true;
            }
            return;
        }
        if (!dashPopoutLoader)
            return;
        _storeDashPosition(x, y, width, section, screen, arguments.length >= 6);
        _dashWantsToggle = true;
        _dashWantsOpen = false;
        dashPopoutLoader.active = true;
    }

    function _onDashPopoutLoaded() {
        if (!dashPopout)
            return;

        if (_dashHasPosition)
            setPosition(dashPopout, _dashPendingX, _dashPendingY, _dashPendingWidth, _dashPendingSection, _dashPendingScreen);

        if (_dashWantsOpen) {
            _dashWantsOpen = false;
            dashPopout.currentTabIndex = _dashPendingTab;
            dashPopout.dashVisible = true;
            return;
        }
        if (_dashWantsToggle) {
            _dashWantsToggle = false;
            if (dashPopout.dashVisible) {
                dashPopout.dashVisible = false;
            } else {
                dashPopout.currentTabIndex = _dashPendingTab;
                dashPopout.dashVisible = true;
            }
        }
    }

    function openBattery(x, y, width, section, screen) {
        if (batteryPopout) {
            setPosition(batteryPopout, x, y, width, section, screen);
            batteryPopout.open();
        }
    }

    function closeBattery() {
        batteryPopout?.close();
    }

    function unloadBattery() {
        _scheduleUnload("battery");
    }

    function toggleBattery(x, y, width, section, screen) {
        if (batteryPopout) {
            setPosition(batteryPopout, x, y, width, section, screen);
            batteryPopout.toggle();
        }
    }

    function openVpn(x, y, width, section, screen) {
        if (vpnPopout) {
            setPosition(vpnPopout, x, y, width, section, screen);
            vpnPopout.open();
        }
    }

    function closeVpn() {
        vpnPopout?.close();
    }

    function unloadVpn() {
        _scheduleUnload("vpn");
    }

    function toggleVpn(x, y, width, section, screen) {
        if (vpnPopout) {
            setPosition(vpnPopout, x, y, width, section, screen);
            vpnPopout.toggle();
        }
    }

    property bool _settingsWantsOpen: false
    property bool _settingsWantsToggle: false

    property string _settingsPendingTab: ""
    property int _settingsPendingTabIndex: -1

    function openSettings() {
        if (settingsModal) {
            settingsModal.show();
        } else if (settingsModalLoader) {
            _settingsWantsOpen = true;
            _settingsWantsToggle = false;
            settingsModalLoader.activeAsync = true;
        }
    }

    function openSettingsWithTab(tabName: string) {
        if (settingsModal) {
            settingsModal.showWithTabName(tabName);
            return;
        }
        if (settingsModalLoader) {
            _settingsPendingTab = tabName;
            _settingsWantsOpen = true;
            _settingsWantsToggle = false;
            settingsModalLoader.activeAsync = true;
        }
    }

    function openSettingsWithTabIndex(tabIndex: int) {
        if (settingsModal) {
            settingsModal.showWithTab(tabIndex);
            return;
        }
        if (settingsModalLoader) {
            _settingsPendingTabIndex = tabIndex;
            _settingsWantsOpen = true;
            _settingsWantsToggle = false;
            settingsModalLoader.activeAsync = true;
        }
    }

    function closeSettings() {
        settingsModal?.close();
    }

    function toggleSettings() {
        if (settingsModal) {
            settingsModal.toggle();
        } else if (settingsModalLoader) {
            _settingsWantsToggle = true;
            _settingsWantsOpen = false;
            settingsModalLoader.activeAsync = true;
        }
    }

    function toggleSettingsWithTab(tabName: string) {
        if (settingsModal) {
            var idx = settingsModal.resolveTabIndex(tabName);
            settingsModal.setTabIndex(idx);
            settingsModal.toggle();
            return;
        }
        if (settingsModalLoader) {
            _settingsPendingTab = tabName;
            _settingsWantsToggle = true;
            _settingsWantsOpen = false;
            settingsModalLoader.activeAsync = true;
        }
    }

    function focusOrToggleSettings() {
        if (settingsModal?.visible) {
            const settingsTitle = I18n.tr("Settings", "settings window title");
            for (const toplevel of ToplevelManager.toplevels.values) {
                if (toplevel.title !== "Settings" && toplevel.title !== settingsTitle)
                    continue;
                if (toplevel.activated) {
                    settingsModal.hide();
                    return;
                }
                toplevel.activate();
                return;
            }
        }
        openSettings();
    }

    function focusOrToggleSettingsWithTab(tabName: string) {
        if (settingsModal?.visible) {
            const settingsTitle = I18n.tr("Settings", "settings window title");
            for (const toplevel of ToplevelManager.toplevels.values) {
                if (toplevel.title !== "Settings" && toplevel.title !== settingsTitle)
                    continue;
                if (toplevel.activated) {
                    settingsModal.hide();
                    return;
                }
                var idx = settingsModal.resolveTabIndex(tabName);
                settingsModal.setTabIndex(idx);
                toplevel.activate();
                return;
            }
        }
        openSettingsWithTab(tabName);
    }

    // ---- Cloud Sync app ----
    // Same lazy-load-then-act shape as Settings: the window is a real toplevel,
    // so it is only built when someone asks for it and torn down when closed.
    property bool _cloudSyncWantsOpen: false
    property bool _cloudSyncWantsToggle: false
    property string _cloudSyncPendingSection: ""

    function openCloudSync() {
        if (cloudSyncModal) {
            cloudSyncModal.show();
        } else if (cloudSyncModalLoader) {
            _cloudSyncWantsOpen = true;
            _cloudSyncWantsToggle = false;
            cloudSyncModalLoader.activeAsync = true;
        }
    }

    function openCloudSyncWithSection(section: string) {
        if (cloudSyncModal) {
            cloudSyncModal.showWithSection(section);
            return;
        }
        if (cloudSyncModalLoader) {
            _cloudSyncPendingSection = section;
            _cloudSyncWantsOpen = true;
            _cloudSyncWantsToggle = false;
            cloudSyncModalLoader.activeAsync = true;
        }
    }

    function closeCloudSync() {
        cloudSyncModal?.hide();
    }

    function toggleCloudSync() {
        if (cloudSyncModal) {
            cloudSyncModal.toggle();
        } else if (cloudSyncModalLoader) {
            _cloudSyncWantsToggle = true;
            _cloudSyncWantsOpen = false;
            cloudSyncModalLoader.activeAsync = true;
        }
    }

    function _onCloudSyncModalLoaded() {
        if (_cloudSyncWantsOpen) {
            _cloudSyncWantsOpen = false;
            if (_cloudSyncPendingSection) {
                cloudSyncModal?.showWithSection(_cloudSyncPendingSection);
                _cloudSyncPendingSection = "";
            } else {
                cloudSyncModal?.show();
            }
            return;
        }
        if (_cloudSyncWantsToggle) {
            _cloudSyncWantsToggle = false;
            if (_cloudSyncPendingSection) {
                cloudSyncModal?.showWithSection(_cloudSyncPendingSection);
                _cloudSyncPendingSection = "";
                return;
            }
            cloudSyncModal?.toggle();
        }
    }

    function unloadCloudSync() {
        _scheduleUnload("cloudSync");
    }

    function _unloadCloudSyncNow() {
        if (!cloudSyncModalLoader)
            return;
        if (cloudSyncModal && cloudSyncModal.visible)
            return;
        cloudSyncModal = null;
        cloudSyncModalLoader.active = false;
    }

    function unloadSettings() {
        _scheduleUnload("settings");
    }

    function _unloadSettingsNow() {
        if (!settingsModalLoader)
            return;
        if (settingsModal && settingsModal.visible)
            return;
        settingsModal = null;
        settingsModalLoader.active = false;
    }

    function _onSettingsModalLoaded() {
        if (_settingsWantsOpen) {
            _settingsWantsOpen = false;
            if (_settingsPendingTabIndex >= 0) {
                settingsModal?.showWithTab(_settingsPendingTabIndex);
                _settingsPendingTabIndex = -1;
            } else if (_settingsPendingTab) {
                settingsModal?.showWithTabName(_settingsPendingTab);
                _settingsPendingTab = "";
            } else {
                settingsModal?.show();
            }
            return;
        }
        if (_settingsWantsToggle) {
            _settingsWantsToggle = false;
            if (_settingsPendingTabIndex >= 0) {
                settingsModal?.setTabIndex(_settingsPendingTabIndex);
                _settingsPendingTabIndex = -1;
            } else if (_settingsPendingTab) {
                var idx = settingsModal?.resolveTabIndex(_settingsPendingTab) ?? -1;
                settingsModal?.setTabIndex(idx);
                _settingsPendingTab = "";
            }
            settingsModal?.toggle();
        }
    }

    function openClipboardHistory() {
        clipboardHistoryModal?.show();
    }

    function closeClipboardHistory() {
        clipboardHistoryModal?.hide();
    }

    function unloadClipboardHistoryPopout() {
        _scheduleUnload("clipboardHistory");
    }

    function unloadLayoutPopout() {
        _scheduleUnload("layout");
    }

    function openPowerMenu() {
        powerMenuModal?.openCentered();
    }

    function closePowerMenu() {
        powerMenuModal?.close();
    }

    function togglePowerMenu() {
        if (powerMenuModal) {
            if (powerMenuModal.shouldBeVisible) {
                powerMenuModal.close();
            } else {
                powerMenuModal.openCentered();
            }
        }
    }

    function openPowerProfileModal() {
        if (powerProfileModal) {
            powerProfileModal.openCentered();
        } else if (powerProfileModalLoader) {
            powerProfileModalLoader.active = true;
            Qt.callLater(() => powerProfileModal?.openCentered());
        }
    }

    function closePowerProfileModal() {
        powerProfileModal?.close();
    }

    function togglePowerProfileModal() {
        if (powerProfileModal) {
            if (powerProfileModal.shouldBeVisible) {
                powerProfileModal.close();
            } else {
                powerProfileModal.openCentered();
            }
        } else if (powerProfileModalLoader) {
            powerProfileModalLoader.active = true;
            Qt.callLater(() => {
                if (powerProfileModal) {
                    if (powerProfileModal.shouldBeVisible) {
                        powerProfileModal.close();
                    } else {
                        powerProfileModal.openCentered();
                    }
                }
            });
        }
    }

    function showProcessListModal() {
        if (processListModal) {
            processListModal.show();
        } else if (processListModalLoader) {
            processListModalLoader.active = true;
            Qt.callLater(() => processListModal?.show());
        }
    }

    function hideProcessListModal() {
        processListModal?.hide();
    }

    function unloadProcessListModal() {
        if (processListModalLoader) {
            processListModal = null;
            processListModalLoader.active = false;
        }
    }

    function toggleProcessListModal() {
        if (processListModal) {
            processListModal.toggle();
        } else if (processListModalLoader) {
            processListModalLoader.active = true;
            Qt.callLater(() => processListModal?.show());
        }
    }

    function showColorPicker() {
        colorPickerModal?.show();
    }

    function hideColorPicker() {
        colorPickerModal?.close();
    }

    function showNotificationModal() {
        notificationModal?.show();
    }

    function hideNotificationModal() {
        notificationModal?.close();
    }

    function showWifiPasswordModal(ssid) {
        if (wifiPasswordModalLoader)
            wifiPasswordModalLoader.active = true;
        if (wifiPasswordModal) {
            wifiPasswordModal.show(ssid);
        } else {
            Qt.callLater(() => wifiPasswordModal?.show(ssid));
        }
    }

    function showWifiQRCodeModal(ssid) {
        if (wifiQRCodeModalLoader)
            wifiQRCodeModalLoader.active = true;
        if (wifiQRCodeModal)
            wifiQRCodeModal.show(ssid);
    }

    function showHiddenNetworkModal() {
        if (wifiPasswordModalLoader)
            wifiPasswordModalLoader.active = true;
        if (wifiPasswordModal) {
            wifiPasswordModal.showHidden();
        } else {
            Qt.callLater(() => wifiPasswordModal?.showHidden());
        }
    }

    function hideWifiPasswordModal() {
        wifiPasswordModal?.hide();
    }

    function showNetworkInfoModal() {
        networkInfoModal?.show();
    }

    function hideNetworkInfoModal() {
        networkInfoModal?.close();
    }

    function closeNotepadSlideouts() {
        for (var i = 0; i < notepadSlideouts.length; i++) {
            if (notepadSlideouts[i] && notepadSlideouts[i].isVisible)
                notepadSlideouts[i].hide();
        }
    }

    function openNotepadSlideout() {
        notepadPopout?.hide();
        if (notepadSlideouts.length > 0) {
            notepadSlideouts[0]?.show();
        }
    }

    // Keep the notepad in a single presentation for default modes
    Connections {
        target: SettingsData
        function onNotepadDefaultModeChanged() {
            if (SettingsData.notepadDefaultMode === "popout") {
                var hadSlideout = false;
                for (var i = 0; i < root.notepadSlideouts.length; i++) {
                    if (root.notepadSlideouts[i] && root.notepadSlideouts[i].isVisible) {
                        hadSlideout = true;
                        root.notepadSlideouts[i].hide();
                    }
                }
                if (hadSlideout)
                    root.openNotepadPopout();
            } else if (root.notepadPopout && root.notepadPopout.visible) {
                root.notepadPopout.hide();
                root.openNotepadSlideout();
            }
        }
    }

    function openNotepad() {
        if (SettingsData.notepadDefaultMode === "popout") {
            openNotepadPopout();
            return;
        }
        openNotepadSlideout();
    }

    function closeNotepad() {
        if (SettingsData.notepadDefaultMode === "popout") {
            notepadPopout?.hide();
            return;
        }
        if (notepadSlideouts.length > 0) {
            notepadSlideouts[0]?.hide();
        }
    }

    function toggleNotepad() {
        if (SettingsData.notepadDefaultMode === "popout") {
            toggleNotepadPopout();
            return;
        }
        if (notepadSlideouts.length > 0) {
            notepadSlideouts[0]?.toggle();
        }
    }

    property var notepadPopout: null
    property var notepadPopoutLoader: null
    property bool _notepadPopoutWantsOpen: false

    function openNotepadPopout() {
        closeNotepadSlideouts();
        if (notepadPopout) {
            notepadPopout.show();
        } else if (notepadPopoutLoader) {
            _notepadPopoutWantsOpen = true;
            notepadPopoutLoader.active = true;
        }
    }

    function _onNotepadPopoutLoaded() {
        if (_notepadPopoutWantsOpen && notepadPopout) {
            _notepadPopoutWantsOpen = false;
            notepadPopout.show();
        }
    }

    function toggleNotepadPopout() {
        if (notepadPopout) {
            if (!notepadPopout.visible)
                closeNotepadSlideouts();
            notepadPopout.toggle();
        } else {
            openNotepadPopout();
        }
    }
}
