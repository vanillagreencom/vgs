pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root

    property int refCount: 0

    property bool sysupdateAvailable: false

    property var availableUpdates: []
    property bool isChecking: false
    property bool isUpgrading: false
    property bool hasError: false
    property string errorMessage: ""
    property string errorCode: ""
    property var backends: []
    property string distribution: ""
    property string distributionPretty: ""
    property string pkgManager: ""
    property bool distributionSupported: false
    property var recentLog: []
    property int intervalSeconds: 1800
    property int lastCheckUnix: 0
    property int nextCheckUnix: 0

    readonly property int updateCount: availableUpdates.length
    readonly property bool helperAvailable: sysupdateAvailable && backends.length > 0

    Connections {
        target: VGSBackendService
        function onCapabilitiesReceived() {
            root.checkCapabilities();
        }
        function onConnectionStateChanged() {
            if (VGSBackendService.isConnected) {
                root.checkCapabilities();
            } else {
                root.sysupdateAvailable = false;
                root._startupCheckDone = false;
            }
            Qt.callLater(() => root._maybeStartupCheck());
        }
        function onSysupdateStateUpdate(data) {
            root._applyState(data);
        }
    }

    Connections {
        target: SettingsData
        function onUpdaterCheckOnStartChanged() {
            Qt.callLater(() => root._maybeStartupCheck());
        }
        function on_HasLoadedChanged() {
            Qt.callLater(() => root._maybeStartupCheck());
        }
    }

    Component.onCompleted: {
        if (VGSBackendService.backendAvailable) {
            checkCapabilities();
        }
        Qt.callLater(() => root._maybeStartupCheck());
    }

    function checkCapabilities() {
        if (!VGSBackendService.capabilities || !Array.isArray(VGSBackendService.capabilities)) {
            sysupdateAvailable = false;
            Qt.callLater(() => root._maybeStartupCheck());
            return;
        }
        const has = VGSBackendService.capabilities.includes("sysupdate");
        if (has && !sysupdateAvailable) {
            sysupdateAvailable = true;
            requestState();
        } else if (!has) {
            sysupdateAvailable = false;
        }
        Qt.callLater(() => root._maybeStartupCheck());
    }

    function requestState() {
        if (!VGSBackendService.isConnected || !sysupdateAvailable) {
            return;
        }
        VGSBackendService.sysupdateGetState(resp => {
            if (resp && resp.result) {
                _applyState(resp.result);
            }
        });
    }

    function _applyState(data) {
        if (!data) {
            return;
        }
        availableUpdates = data.packages || [];
        backends = data.backends || [];
        distribution = data.distro || "";
        distributionPretty = data.distroPretty || "";
        distributionSupported = (backends.length > 0);
        recentLog = data.recentLog || [];
        intervalSeconds = data.intervalSeconds || 1800;
        lastCheckUnix = data.lastCheckUnix || 0;
        nextCheckUnix = data.nextCheckUnix || 0;

        const phase = data.phase || "idle";
        switch (phase) {
        case "refreshing":
            isChecking = true;
            isUpgrading = false;
            break;
        case "upgrading":
            isChecking = false;
            isUpgrading = true;
            break;
        default:
            isChecking = false;
            isUpgrading = false;
        }

        if (data.error) {
            hasError = true;
            errorMessage = data.error.message || "";
            errorCode = data.error.code || "";
        } else {
            hasError = false;
            errorMessage = "";
            errorCode = "";
        }

        if (backends.length > 0) {
            const sys = backends.find(b => b.repo === "system" || b.repo === "ostree");
            pkgManager = sys ? sys.id : backends[0].id;
        } else {
            pkgManager = "";
        }
    }

    function checkForUpdates(callback) {
        VGSBackendService.sysupdateRefresh(false, response => {
            if (response && response.result)
                _applyState(response.result);
            if (response && response.error)
                _applyError("refresh_failed", response.error);
            if (callback)
                callback(response);
        });
    }

    function setInterval(seconds) {
        VGSBackendService.sysupdateSetInterval(seconds, response => {
            if (response && response.result)
                _applyState(response.result);
            if (response && response.error)
                _applyError("interval_failed", response.error);
        });
    }

    function _applyError(code, message) {
        hasError = true;
        errorCode = code || "sysupdate_failed";
        errorMessage = message || "";
    }

    property bool _startupCheckDone: false

    function _maybeStartupCheck() {
        if (refCount <= 0) {
            _startupCheckDone = false;
            return;
        }
        if (!SettingsData.updaterCheckOnStart)
            return;
        if (_startupCheckDone)
            return;
        if (!VGSBackendService.isConnected || !sysupdateAvailable)
            return;
        _startupCheckDone = true;
        Qt.callLater(() => root.checkForUpdates());
    }

    onRefCountChanged: {
        if (refCount <= 0)
            _startupCheckDone = false;
        _syncAcquire();
        Qt.callLater(() => root._maybeStartupCheck());
    }
    onSysupdateAvailableChanged: _syncAcquire()

    property bool _acquired: false

    function _syncAcquire() {
        const want = refCount > 0 && sysupdateAvailable;
        if (want === _acquired) {
            return;
        }
        _acquired = want;
        if (want) {
            VGSBackendService.sysupdateAcquire(null);
            return;
        }
        VGSBackendService.sysupdateRelease(null);
    }

}
