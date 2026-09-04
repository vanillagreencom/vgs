pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("DisplayService")

    property bool brightnessAvailable: devices.length > 0
    readonly property bool backendBrightnessAvailable: VGSBackendService.isConnected && VGSBackendService.capabilities.includes("brightness") && VGSBackendService.methods.includes("brightness.getState") && VGSBackendService.methods.includes("brightness.setBrightness")
    property var devices: []
    property var deviceBrightness: ({})
    property var deviceBrightnessUserSet: ({})
    property var deviceMaxCache: ({})
    property var userControlledDevices: ({})
    property var brightnessWriteState: ({})
    property int brightnessWriteSeq: 0
    property var lastBrightnessWriteSeqByDevice: ({})
    property var pendingOsdDevices: ({})
    property int brightnessVersion: 0
    property string currentDevice: ""
    property string lastIpcDevice: ""
    property int brightnessLevel: {
        brightnessVersion;
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice);
        if (!deviceToUse) {
            return 50;
        }

        return getDeviceBrightness(deviceToUse);
    }
    property int maxBrightness: 100
    property bool brightnessInitialized: false
    property bool suppressOsd: true
    property string lastBrightnessError: ""
    // A dead i2c/PCI bus wedges every scan; past the threshold, scanning stops
    // until a lift: hotplug, resume, backend arrival, a successful ddc
    // write, or a late success from a scan already in flight. Each lift starts
    // a counting episode (scanEpoch): failures of scans launched before the
    // lift never count, every failure inside the episode does, and the
    // threshold sits above scanRetryLadderAttempts so a fully failed ladder
    // alone cannot latch the quarantine.
    readonly property int scanQuarantineThreshold: 4
    // Both post-event retry ladders (hotplug and resume) run this many
    // staggered scans.
    readonly property int scanRetryLadderAttempts: 3
    property int consecutiveScanFailures: 0
    property bool scanQuarantined: false
    property int scanGeneration: 0
    property int settledScanGeneration: 0
    property int scanEpoch: 0
    // Bound recovery rescans after a committed failure clears brightness state.
    // Each failed retry counts toward bus quarantine.
    readonly property int scanRecoveryRetryBudget: 3
    property int scanRecoveryRetriesUsed: 0

    signal brightnessChanged(bool showOsd)
    signal deviceSwitched

    // Startup-era CLI failures must not hold the quarantine once the daemon can answer.
    onBackendBrightnessAvailableChanged: {
        if (backendBrightnessAvailable) {
            liftScanQuarantine();
            rescanDevices();
        }
    }

    function isDisplayBrightnessClass(deviceClass) {
        return deviceClass === "backlight" || deviceClass === "ddc" || deviceClass === "apple";
    }

    function applyBrightnessStateJson(output, scanWriteSeq, scanBlockedDevices) {
        let state = null;
        try {
            state = JSON.parse(output || "{}");
        } catch (e) {
            log.warn("Failed to parse brightness helper output:", e);
            return false;
        }
        if (state && state.errors && state.errors.length > 0) {
            lastBrightnessError = state.errors.join("\n");
            log.warn("Brightness helper warnings:", lastBrightnessError);
        }
        // A response with no devices array applied nothing and must not read
        // as a recovered bus; an explicit empty list is a genuine answer.
        if (!state || !state.devices) {
            return false;
        }
        updateFromBrightnessState(state, scanWriteSeq, scanBlockedDevices);
        return true;
    }

    function getDisplayValueForDevice(device) {
        const isExponential = SessionData.getBrightnessExponential(device.id);
        if (!isExponential) {
            return device.currentPercent;
        }

        const userSetValue = deviceBrightnessUserSet[device.id];
        if (userSetValue !== undefined) {
            const exponent = SessionData.getBrightnessExponent(device.id);
            const expectedHardware = Math.round(Math.pow(userSetValue / 100.0, exponent) * 100.0);
            if (Math.abs(device.currentPercent - expectedHardware) <= 2) {
                return userSetValue;
            }

            const newUserSet = Object.assign({}, deviceBrightnessUserSet);
            delete newUserSet[device.id];
            deviceBrightnessUserSet = newUserSet;
            SessionData.clearBrightnessUserSetValue(device.id);
        }

        return linearToExponential(device.currentPercent, device.id);
    }

    function scanHasLocalWriteConflict(scanSeq, scanBlockedDevices) {
        if (scanBlockedDevices && Object.keys(scanBlockedDevices).length > 0) {
            return true;
        }
        const writes = lastBrightnessWriteSeqByDevice || {};
        for (const deviceName in writes) {
            if ((writes[deviceName] || 0) > scanSeq) {
                return true;
            }
        }
        return false;
    }

    function isDeviceGuardedFromScan(deviceId, scanSeq, scanBlockedDevices) {
        return isDeviceUserControlled(deviceId) || (lastBrightnessWriteSeqByDevice[deviceId] || 0) > scanSeq || !!(scanBlockedDevices && scanBlockedDevices[deviceId]);
    }

    function snapshotScanBlockedDevices() {
        const blocked = Object.assign({}, brightnessWriteState);
        for (const device of devices || []) {
            if (isDeviceUserControlled(device.id)) {
                blocked[device.id] = true;
            }
        }
        return blocked;
    }

    property bool nightModeActive: nightModeEnabled

    property bool nightModeEnabled: false
    property bool automationAvailable: false
    property bool gammaControlAvailable: false
    property int resumeRecoveryAttempt: 0

    property var gammaState: ({})
    property int gammaCurrentTemp: gammaState?.currentTemp ?? 0
    property string gammaNextTransition: gammaState?.nextTransition ?? ""
    property string gammaSunriseTime: gammaState?.sunriseTime ?? ""
    property string gammaSunsetTime: gammaState?.sunsetTime ?? ""
    property string gammaDawnTime: gammaState?.dawnTime ?? ""
    property string gammaNightTime: gammaState?.nightTime ?? ""
    property bool gammaIsDay: gammaState?.isDay ?? true
    property real gammaSunPosition: gammaState?.sunPosition ?? 0
    property int gammaLowTemp: gammaState?.config?.LowTemp ?? 0
    property int gammaHighTemp: gammaState?.config?.HighTemp ?? 0

    function markDeviceUserControlled(deviceId) {
        const newControlled = Object.assign({}, userControlledDevices);
        newControlled[deviceId] = Date.now();
        userControlledDevices = newControlled;
    }

    function isDeviceUserControlled(deviceId) {
        if (brightnessWriteState[deviceId]) {
            return true;
        }
        const controlTime = userControlledDevices[deviceId];
        if (!controlTime) {
            return false;
        }
        return (Date.now() - controlTime) < 3000;
    }

    function clearDeviceUserControlled(deviceId) {
        const newControlled = Object.assign({}, userControlledDevices);
        delete newControlled[deviceId];
        userControlledDevices = newControlled;
    }

    function markDevicePendingOsd(deviceId) {
        const newPending = Object.assign({}, pendingOsdDevices);
        newPending[deviceId] = true;
        pendingOsdDevices = newPending;
    }

    function clearDevicePendingOsd(deviceId) {
        const newPending = Object.assign({}, pendingOsdDevices);
        delete newPending[deviceId];
        pendingOsdDevices = newPending;
    }

    function updateSingleDevice(device, force, showOsd) {
        if (device.class === "leds") {
            return;
        }

        const isUserControlled = force !== true && isDeviceUserControlled(device.id);
        if (isUserControlled) {
            return;
        }

        const deviceIndex = devices.findIndex(d => d.id === device.id);
        if (deviceIndex !== -1) {
            const newDevices = [...devices];
            const cachedMax = deviceMaxCache[device.id];

            let displayMax = cachedMax || ((device.class === "ddc" || device.class === "apple") ? device.max : 100);
            if (displayMax > 0 && !cachedMax) {
                const newCache = Object.assign({}, deviceMaxCache);
                newCache[device.id] = displayMax;
                deviceMaxCache = newCache;
            }

            newDevices[deviceIndex] = {
                "id": device.id,
                "name": device.name || device.id,
                "label": device.label || device.name || device.id,
                "class": device.class,
                "current": device.current,
                "percentage": device.currentPercent,
                "max": device.max,
                "backend": device.backend,
                "displayMax": displayMax
            };
            devices = newDevices;
        }

        const displayValue = getDisplayValueForDevice(device);

        const oldValue = deviceBrightness[device.id];
        const newBrightness = Object.assign({}, deviceBrightness);
        newBrightness[device.id] = displayValue;
        deviceBrightness = newBrightness;
        brightnessVersion++;

        const isPendingOsd = pendingOsdDevices[device.id] === true;
        if (isPendingOsd) {
            clearDevicePendingOsd(device.id);
            if (showOsd !== false && !suppressOsd) {
                brightnessChanged(true);
            }
            return;
        }

        if (!brightnessInitialized || oldValue === displayValue) {
            return;
        }
        if (suppressOsd) {
            return;
        }
        if (showOsd !== false) {
            brightnessChanged(true);
        }
    }

    function updateFromBrightnessState(state, scanWriteSeq, scanBlockedDevices) {
        const scanSeq = typeof scanWriteSeq === "number" ? scanWriteSeq : brightnessWriteSeq;
        if (state.devices.length === 0 && scanHasLocalWriteConflict(scanSeq, scanBlockedDevices)) {
            return;
        }

        const newMaxCache = Object.assign({}, deviceMaxCache);
        const existingDevices = devices || [];
        const mappedDevices = state.devices.map(d => {
            if (isDeviceGuardedFromScan(d.id, scanSeq, scanBlockedDevices)) {
                const existing = existingDevices.find(device => device.id === d.id);
                if (existing) {
                    return existing;
                }
            }
            const cachedMax = deviceMaxCache[d.id];
            let displayMax = cachedMax || ((d.class === "ddc" || d.class === "apple") ? d.max : 100);
            if (displayMax > 0 && !cachedMax) {
                newMaxCache[d.id] = displayMax;
            }
            return {
                "id": d.id,
                "name": d.name || d.id,
                "label": d.label || d.name || d.id,
                "class": d.class,
                "current": d.current,
                "percentage": d.currentPercent,
                "max": d.max,
                "backend": d.backend,
                "displayMax": displayMax
            };
        });
        const mappedIds = mappedDevices.map(d => d.id);
        for (const existing of existingDevices) {
            if (!mappedIds.includes(existing.id) && isDeviceGuardedFromScan(existing.id, scanSeq, scanBlockedDevices)) {
                mappedDevices.push(existing);
            }
        }
        devices = mappedDevices;
        deviceMaxCache = newMaxCache;

        const newBrightness = {};
        let anyDeviceBrightnessChanged = false;

        for (const device of state.devices) {
            const oldValue = deviceBrightness[device.id];

            if (isDeviceGuardedFromScan(device.id, scanSeq, scanBlockedDevices) && oldValue !== undefined) {
                newBrightness[device.id] = oldValue;
                continue;
            }

            newBrightness[device.id] = getDisplayValueForDevice(device);

            const newValue = newBrightness[device.id];
            if (oldValue !== undefined && oldValue !== newValue) {
                anyDeviceBrightnessChanged = true;
            }
        }
        for (const deviceName in deviceBrightness) {
            if (newBrightness[deviceName] === undefined && isDeviceGuardedFromScan(deviceName, scanSeq, scanBlockedDevices)) {
                newBrightness[deviceName] = deviceBrightness[deviceName];
            }
        }
        deviceBrightness = newBrightness;
        brightnessVersion++;

        brightnessAvailable = devices.length > 0;

        if (devices.length > 0 && !currentDevice) {
            const lastDevice = SessionData.lastBrightnessDevice || "";
            const deviceExists = devices.some(d => d.id === lastDevice);
            if (deviceExists) {
                setCurrentDevice(lastDevice, false);
            } else {
                const backlight = devices.find(d => d.class === "backlight");
                const nonKbdDevice = devices.find(d => !d.id.includes("kbd"));
                const defaultDevice = backlight || nonKbdDevice || devices[0];
                setCurrentDevice(defaultDevice.id, false);
            }
        }

        const shouldShowOsd = brightnessInitialized && anyDeviceBrightnessChanged && !suppressOsd;

        if (!brightnessInitialized) {
            brightnessInitialized = true;
        }

        if (shouldShowOsd) {
            brightnessChanged(true);
        }
    }

    function setBrightness(percentage, device, suppressOsd) {
        const actualDevice = device === "" ? getDefaultDevice() : (device || currentDevice || getDefaultDevice());
        if (!actualDevice) {
            log.warn("No device selected for brightness change");
            return;
        }

        if (actualDevice !== lastIpcDevice) {
            lastIpcDevice = actualDevice;
        }

        const deviceInfo = getCurrentDeviceInfoByName(actualDevice);
        const isExponential = SessionData.getBrightnessExponential(actualDevice);

        let minValue = 0;
        let maxValue = 100;

        switch (true) {
        case isExponential:
            minValue = 1;
            maxValue = 100;
            break;
        default:
            minValue = (deviceInfo && isDisplayBrightnessClass(deviceInfo.class)) ? 1 : 0;
            maxValue = deviceInfo?.displayMax || 100;
            break;
        }

        if (maxValue <= 0) {
            log.warn("Invalid max value for device", actualDevice, "- skipping brightness change");
            return;
        }

        const clampedValue = Math.round(Math.max(minValue, Math.min(maxValue, percentage)));

        const isLedDevice = deviceInfo?.class === "leds";

        if (suppressOsd) {
            markDeviceUserControlled(actualDevice);
        } else if (!isLedDevice) {
            markDevicePendingOsd(actualDevice);
        }

        const newBrightness = Object.assign({}, deviceBrightness);
        newBrightness[actualDevice] = clampedValue;
        deviceBrightness = newBrightness;
        brightnessVersion++;
        brightnessChanged(false);

        if (isLedDevice && !suppressOsd) {
            brightnessChanged(true);
        }

        if (isExponential) {
            const newUserSet = Object.assign({}, deviceBrightnessUserSet);
            newUserSet[actualDevice] = clampedValue;
            deviceBrightnessUserSet = newUserSet;
            SessionData.setBrightnessUserSetValue(actualDevice, clampedValue);
        }

        let hardwareValue = clampedValue;
        if (isExponential) {
            const exponent = SessionData.getBrightnessExponent(actualDevice);
            hardwareValue = Math.max(1, Math.min(100, Math.round(Math.pow(clampedValue / 100.0, exponent) * 100.0)));
        }

        queueBrightnessWrite(actualDevice, hardwareValue, suppressOsd !== true && !isLedDevice);
    }

    function queueBrightnessWrite(deviceName, hardwareValue, showOsd) {
        brightnessWriteSeq++;
        const previous = brightnessWriteState[deviceName] || {};
        const nextWrites = Object.assign({}, brightnessWriteState);
        nextWrites[deviceName] = {
            "hardwareValue": hardwareValue,
            "seq": brightnessWriteSeq,
            "inFlight": previous.inFlight === true,
            "inFlightSeq": previous.inFlightSeq || 0,
            "showOsd": showOsd === true
        };
        brightnessWriteState = nextWrites;
        const nextWriteSeq = Object.assign({}, lastBrightnessWriteSeqByDevice);
        nextWriteSeq[deviceName] = brightnessWriteSeq;
        lastBrightnessWriteSeqByDevice = nextWriteSeq;
        brightnessCommitTimer.restart();
    }

    function flushBrightnessWrites() {
        const writes = brightnessWriteState || {};
        for (const deviceName in writes) {
            const state = writes[deviceName];
            if (!state || state.inFlight)
                continue;
            sendBrightnessWrite(deviceName, state.seq, state.hardwareValue);
        }
    }

    function sendBrightnessWrite(deviceName, seq, hardwareValue) {
        const state = brightnessWriteState[deviceName];
        if (!state || state.seq !== seq || state.inFlight)
            return;

        const nextWrites = Object.assign({}, brightnessWriteState);
        nextWrites[deviceName] = Object.assign({}, state, {
            "inFlight": true,
            "inFlightSeq": seq
        });
        brightnessWriteState = nextWrites;

        const handleResponse = response => {
            const latest = brightnessWriteState[deviceName];
            if (!latest)
                return;

            if (latest.seq !== seq) {
                const retryWrites = Object.assign({}, brightnessWriteState);
                if (retryWrites[deviceName]) {
                    retryWrites[deviceName] = Object.assign({}, retryWrites[deviceName], {
                        "inFlight": false,
                        "inFlightSeq": 0
                    });
                    brightnessWriteState = retryWrites;
                    brightnessCommitTimer.restart();
                }
                return;
            }

            const remainingWrites = Object.assign({}, brightnessWriteState);
            delete remainingWrites[deviceName];
            brightnessWriteState = remainingWrites;

            if (response.error) {
                log.error("Failed to set brightness:", response.error);
                ToastService.showError(I18n.tr("Failed to set brightness"), response.error, "", "brightness");
                clearDeviceUserControlled(deviceName);
                if (SessionData.getBrightnessExponential(deviceName)) {
                    const newUserSet = Object.assign({}, deviceBrightnessUserSet);
                    delete newUserSet[deviceName];
                    deviceBrightnessUserSet = newUserSet;
                    SessionData.clearBrightnessUserSetValue(deviceName);
                }
                rescanDevices();
                return;
            }

            ToastService.dismissCategory("brightness");
            const result = response.result || response;
            // The lift needs the class the write actually exercised: the
            // response's device is authoritative, the local list the fallback.
            const writtenClass = (result.device && result.device.class)
                || (getCurrentDeviceInfoByName(deviceName) || {}).class || "";
            if (writeLiftsQuarantine(writtenClass)) {
                liftScanQuarantine();
            }
            if (result.device) {
                updateSingleDevice(result.device, true, latest.showOsd === true);
                if (!brightnessAvailable) {
                    // A committed scan failure cleared the device list; this
                    // write reached the hardware, so a scan can rebuild it.
                    rescanDevices();
                }
            } else {
                rescanDevices();
            }
        };

        if (backendBrightnessAvailable) {
            VGSBackendService.sendRequest("brightness.setBrightness", {
                "device": deviceName,
                "percent": hardwareValue
            }, handleResponse);
            return;
        }

        Proc.runCommand(null, [Paths.vshellCli, "brightness", "set", deviceName, String(hardwareValue), "--json"], (output, exitCode, errorOutput) => {
            if (exitCode !== 0) {
                handleResponse({ "error": (errorOutput || output || I18n.tr("Unknown brightness helper error")).trim() });
                return;
            }
            try {
                handleResponse(JSON.parse(output || "{}"));
            } catch (e) {
                handleResponse({ "error": I18n.tr("Invalid brightness helper response") });
            }
        }, 0, 6000);
    }

    function setCurrentDevice(deviceName, saveToSession = false) {
        if (currentDevice === deviceName) {
            return;
        }

        currentDevice = deviceName;
        lastIpcDevice = deviceName;

        if (saveToSession) {
            SessionData.setLastBrightnessDevice(deviceName);
        }

        deviceSwitched();
    }

    function getDeviceBrightness(deviceName) {
        if (!deviceName) {
            return 50;
        }

        if (deviceName in deviceBrightness) {
            return deviceBrightness[deviceName];
        }

        return 50;
    }

    function linearToExponential(linearPercent, deviceName) {
        const exponent = SessionData.getBrightnessExponent(deviceName);
        const hardwarePercent = linearPercent / 100.0;
        const normalizedPercent = Math.pow(hardwarePercent, 1.0 / exponent);
        return Math.round(normalizedPercent * 100.0);
    }

    function getDefaultDevice() {
        for (const device of devices) {
            if (device.class === "backlight") {
                return device.id;
            }
        }
        return devices.length > 0 ? devices[0].id : "";
    }

    function getPinnedDeviceForFocusedScreen() {
        const focusedScreen = CompositorService.getFocusedScreen();
        if (!focusedScreen)
            return "";

        const pins = SettingsData.brightnessDevicePins || {};
        const screenKey = SettingsData.getScreenDisplayName(focusedScreen);
        if (!screenKey)
            return "";

        const pinnedDevice = pins[screenKey];
        if (!pinnedDevice)
            return "";

        const deviceExists = devices.some(d => d.id === pinnedDevice);
        if (!deviceExists)
            return "";

        return pinnedDevice;
    }

    function getPreferredDevice() {
        const pinned = getPinnedDeviceForFocusedScreen();
        if (pinned)
            return pinned;

        return getDefaultDevice();
    }

    function getCurrentDeviceInfo() {
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice);
        if (!deviceToUse) {
            return null;
        }

        for (const device of devices) {
            if (device.id === deviceToUse) {
                return device;
            }
        }
        return null;
    }

    function isCurrentDeviceReady() {
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice);
        return deviceToUse !== "";
    }

    function getCurrentDeviceInfoByName(deviceName) {
        if (!deviceName) {
            return null;
        }

        for (const device of devices) {
            if (device.id === deviceName) {
                return device;
            }
        }
        return null;
    }

    function getDeviceMax(deviceName) {
        const deviceInfo = getCurrentDeviceInfoByName(deviceName);
        if (!deviceInfo) {
            return 100;
        }
        return deviceInfo.displayMax || 100;
    }

    function enableNightMode() {
        if (!gammaControlAvailable) {
            ToastService.showWarning(I18n.tr("Night mode failed: VGS gamma control not available"));
            return;
        }

        nightModeEnabled = true;
        SessionData.setNightModeEnabled(true);

        // Configure gamma while disabled, then enable it to avoid visible resets from repeated hyprsunset restarts.
        const finishEnable = () => {
            VGSBackendService.sendRequest("wayland.gamma.setEnabled", {
                "enabled": true
            }, response => {
                if (response.error) {
                    log.error("Failed to enable gamma control:", response.error);
                    ToastService.showError(I18n.tr("Failed to enable night mode"), response.error, "", "night-mode");
                    nightModeEnabled = false;
                    SessionData.setNightModeEnabled(false);
                    return;
                }
                ToastService.dismissCategory("night-mode");
            });
        };

        if (SessionData.nightModeAutoEnabled) {
            startAutomation(finishEnable);
        } else {
            applyNightModeDirectly(finishEnable);
        }
    }

    function disableNightMode() {
        nightModeEnabled = false;
        SessionData.setNightModeEnabled(false);

        if (!gammaControlAvailable) {
            return;
        }

        VGSBackendService.sendRequest("wayland.gamma.setEnabled", {
            "enabled": false
        }, response => {
            if (response.error) {
                log.error("Failed to disable gamma control:", response.error);
                ToastService.showError(I18n.tr("Failed to disable night mode"), response.error, "", "night-mode");
            } else {
                ToastService.dismissCategory("night-mode");
            }
        });
    }

    function toggleNightMode() {
        if (nightModeEnabled) {
            disableNightMode();
        } else {
            enableNightMode();
        }
    }

    function applyNightModeDirectly(onDone) {
        const temperature = SessionData.nightModeTemperature || 4000;

        VGSBackendService.sendRequest("wayland.gamma.setManualTimes", {
            "sunrise": null,
            "sunset": null
        }, response => {
            if (response.error) {
                log.error("Failed to clear manual times:", response.error);
                return;
            }

            VGSBackendService.sendRequest("wayland.gamma.setUseIPLocation", {
                "use": false
            }, response => {
                if (response.error) {
                    log.error("Failed to disable IP location:", response.error);
                    return;
                }

                VGSBackendService.sendRequest("wayland.gamma.setTemperature", {
                    "low": temperature,
                    "high": temperature
                }, response => {
                    if (response.error) {
                        log.error("Failed to set temperature:", response.error);
                        ToastService.showError(I18n.tr("Failed to set night mode temperature"), response.error, "", "night-mode");
                        return;
                    }
                    ToastService.dismissCategory("night-mode");
                    if (onDone) {
                        onDone();
                    }
                });
            });
        });
    }

    function startAutomation(onDone) {
        if (!automationAvailable) {
            return;
        }

        const mode = SessionData.nightModeAutoMode || "time";

        switch (mode) {
        case "time":
            startTimeBasedMode(onDone);
            break;
        case "location":
            startLocationBasedMode(onDone);
            break;
        }
    }

    function startTimeBasedMode(onDone) {
        const temperature = SessionData.nightModeTemperature || 4000;
        const highTemp = SessionData.nightModeHighTemperature || 6500;
        const sunriseHour = SessionData.nightModeEndHour;
        const sunriseMinute = SessionData.nightModeEndMinute;
        const sunsetHour = SessionData.nightModeStartHour;
        const sunsetMinute = SessionData.nightModeStartMinute;

        const sunrise = `${String(sunriseHour).padStart(2, '0')}:${String(sunriseMinute).padStart(2, '0')}`;
        const sunset = `${String(sunsetHour).padStart(2, '0')}:${String(sunsetMinute).padStart(2, '0')}`;

        VGSBackendService.sendRequest("wayland.gamma.setUseIPLocation", {
            "use": false
        }, response => {
            if (response.error) {
                log.error("Failed to disable IP location:", response.error);
                return;
            }

            VGSBackendService.sendRequest("wayland.gamma.setTemperature", {
                "low": temperature,
                "high": highTemp
            }, response => {
                if (response.error) {
                    log.error("Failed to set temperature:", response.error);
                    ToastService.showError(I18n.tr("Failed to set night mode temperature"), response.error, "", "night-mode");
                    return;
                }

                VGSBackendService.sendRequest("wayland.gamma.setManualTimes", {
                    "sunrise": sunrise,
                    "sunset": sunset
                }, response => {
                    if (response.error) {
                        log.error("Failed to set manual times:", response.error);
                        ToastService.showError(I18n.tr("Failed to set night mode schedule"), response.error, "", "night-mode");
                        return;
                    }
                    ToastService.dismissCategory("night-mode");
                    if (onDone) {
                        onDone();
                    }
                });
            });
        });
    }

    function startLocationBasedMode(onDone) {
        const temperature = SessionData.nightModeTemperature || 4000;
        const highTemp = SessionData.nightModeHighTemperature || 6500;

        VGSBackendService.sendRequest("wayland.gamma.setManualTimes", {
            "sunrise": null,
            "sunset": null
        }, response => {
            if (response.error) {
                log.error("Failed to clear manual times:", response.error);
                return;
            }

            VGSBackendService.sendRequest("wayland.gamma.setTemperature", {
                "low": temperature,
                "high": highTemp
            }, response => {
                if (response.error) {
                    log.error("Failed to set temperature:", response.error);
                    ToastService.showError(I18n.tr("Failed to set night mode temperature"), response.error, "", "night-mode");
                    return;
                }

                if (SessionData.nightModeUseIPLocation) {
                    VGSBackendService.sendRequest("wayland.gamma.setUseIPLocation", {
                        "use": true
                    }, response => {
                        if (response.error) {
                            log.error("Failed to enable IP location:", response.error);
                            ToastService.showError(I18n.tr("Failed to enable IP location"), response.error, "", "night-mode");
                            return;
                        }
                        ToastService.dismissCategory("night-mode");
                        if (onDone) {
                            onDone();
                        }
                    });
                } else if (SessionData.latitude !== 0.0 && SessionData.longitude !== 0.0) {
                    VGSBackendService.sendRequest("wayland.gamma.setUseIPLocation", {
                        "use": false
                    }, response => {
                        if (response.error) {
                            log.error("Failed to disable IP location:", response.error);
                            return;
                        }

                        VGSBackendService.sendRequest("wayland.gamma.setLocation", {
                            "latitude": SessionData.latitude,
                            "longitude": SessionData.longitude
                        }, response => {
                            if (response.error) {
                                log.error("Failed to set location:", response.error);
                                ToastService.showError(I18n.tr("Failed to set night mode location"), response.error, "", "night-mode");
                                return;
                            }
                            ToastService.dismissCategory("night-mode");
                            if (onDone) {
                                onDone();
                            }
                        });
                    });
                } else {
                    log.warn("Location mode selected but no coordinates set and IP location disabled");
                    if (onDone) {
                        onDone();
                    }
                }
            });
        });
    }

    function setNightModeAutomationMode(mode) {
        SessionData.setNightModeAutoMode(mode);
    }

    function evaluateNightMode() {
        if (!nightModeEnabled) {
            return;
        }

        if (SessionData.nightModeAutoEnabled) {
            restartTimer.nextAction = "automation";
            restartTimer.start();
        } else {
            restartTimer.nextAction = "direct";
            restartTimer.start();
        }
    }

    function runResumeRecoveryPass() {
        checkGammaControlAvailability();
        rescanDevices();

        if (nightModeEnabled) {
            evaluateNightMode();
        }
    }

    function checkGammaControlAvailability() {
        if (!VGSBackendService.isConnected) {
            return;
        }

        if (!VGSBackendService.capabilities.includes("gamma") || !VGSBackendService.methods.includes("wayland.gamma.getState")) {
            gammaControlAvailable = false;
            automationAvailable = false;
            return;
        }

        VGSBackendService.sendRequest("wayland.gamma.getState", null, response => {
            if (response.error) {
                gammaControlAvailable = false;
                automationAvailable = false;
                log.error("Gamma control not available:", response.error);
            } else {
                gammaControlAvailable = true;
                automationAvailable = true;

                if (nightModeEnabled) {
                    // Configure before enabling to avoid visible gamma resets during hyprsunset restarts.
                    const finishEnable = () => {
                        VGSBackendService.sendRequest("wayland.gamma.setEnabled", {
                            "enabled": true
                        }, enableResponse => {
                            if (enableResponse.error) {
                                log.error("Failed to enable gamma control on startup:", enableResponse.error);
                            }
                        });
                    };

                    if (SessionData.nightModeAutoEnabled) {
                        startAutomation(finishEnable);
                    } else {
                        applyNightModeDirectly(finishEnable);
                    }
                }
            }
        });
    }

    Timer {
        id: restartTimer
        property string nextAction: ""
        interval: 250
        repeat: false

        onTriggered: {
            if (nextAction === "automation") {
                startAutomation();
            } else if (nextAction === "direct") {
                applyNightModeDirectly();
            }
            nextAction = "";
        }
    }

    Timer {
        id: resumeRecoveryTimer
        interval: 400
        repeat: false

        onTriggered: {
            runResumeRecoveryPass();
            resumeRecoveryAttempt++;

            if (resumeRecoveryAttempt < scanRetryLadderAttempts) {
                interval = resumeRecoveryAttempt === 1 ? 1400 : 2600;
                restart();
                return;
            }

            resumeRecoveryAttempt = 0;
            interval = 400;
        }
    }

    // BEGIN SCAN VERDICT DECISION
    // scripts/test-brightness-scan-ordering.js evaluates the code between these markers in Node; every input is an argument.
    // Count failures only for scans launched in the current recovery episode.
    // Commit state only for the latest scan while no newer response has settled.
    function scanVerdict(isFailure, myGeneration, myEpoch, latestGeneration, currentEpoch, settledGeneration) {
        if (isFailure) {
            return {
                "count": myEpoch === currentEpoch,
                "commit": myGeneration === latestGeneration && myGeneration > settledGeneration
            };
        }
        return {
            "count": false,
            "commit": myGeneration > settledGeneration
        };
    }

    // A write proves only the path it took: a ddc write exercises the i2c bus
    // the scans wedge on, while backlight and apple writes resolve through
    // the cheap path and say nothing about it. An unknown class is no
    // evidence at all.
    function writeLiftsQuarantine(writtenClass) {
        return writtenClass === "ddc";
    }
    // END SCAN VERDICT DECISION

    function recordScanFailure() {
        consecutiveScanFailures++;
        if (consecutiveScanFailures >= scanQuarantineThreshold && !scanQuarantined) {
            scanQuarantined = true;
            log.warn("Brightness scans quarantined after", consecutiveScanFailures, "consecutive failures; waiting for display hotplug, resume, backend arrival, or a successful ddc write");
        }
    }

    function liftScanQuarantine() {
        consecutiveScanFailures = 0;
        scanQuarantined = false;
        scanEpoch++;
        scanRecoveryRetriesUsed = 0;
        scanRecoveryTimer.stop();
    }

    function rescanDevices() {
        if (scanQuarantined) {
            log.debug("Dropping brightness rescan: scans quarantined until hotplug, resume, backend arrival, or a successful ddc write");
            return;
        }
        const myGeneration = ++scanGeneration;
        const myEpoch = scanEpoch;
        const scanWriteSeq = brightnessWriteSeq;
        const scanBlockedDevices = snapshotScanBlockedDevices();
        const failScan = (kind, message) => {
            const verdict = scanVerdict(true, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration);
            if (!verdict.count && !verdict.commit) {
                log.debug("Dropping brightness rescan", kind, "from before the last recovery");
                return;
            }
            if (message) {
                lastBrightnessError = message;
                log.warn("Brightness rescan failed:", message);
            }
            if (verdict.count) {
                recordScanFailure();
            }
            if (!verdict.commit) {
                log.debug("Keeping newer brightness scan state despite this", kind);
                return;
            }
            if (scanHasLocalWriteConflict(scanWriteSeq, scanBlockedDevices)) {
                log.warn("Ignoring brightness rescan", kind, "while a local write is in flight");
                return;
            }
            settledScanGeneration = myGeneration;
            devices = [];
            deviceBrightness = ({});
            brightnessAvailable = false;
            brightnessVersion++;
            if (scanRecoveryRetriesUsed < scanRecoveryRetryBudget) {
                scanRecoveryRetriesUsed++;
                scanRecoveryTimer.restart();
            }
        };
        const handleResponse = response => {
            if (response.error) {
                failScan("failure", response.error);
                return;
            }
            if (!scanVerdict(false, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration).commit) {
                log.debug("Ignoring brightness rescan response: a newer scan already settled");
                return;
            }
            if (!applyBrightnessStateJson(JSON.stringify(response.result || response), scanWriteSeq, scanBlockedDevices)) {
                failScan("parse failure");
                return;
            }
            settledScanGeneration = myGeneration;
            liftScanQuarantine();
        };

        if (backendBrightnessAvailable) {
            VGSBackendService.sendRequest("brightness.getState", null, handleResponse);
            return;
        }

        Proc.runCommand(null, [Paths.vshellCli, "brightness", "list", "--json"], (output, exitCode, errorOutput) => {
            if (exitCode !== 0 && (!output || output.trim().length === 0)) {
                handleResponse({ "error": (errorOutput || I18n.tr("No brightness devices available")).trim() });
                return;
            }
            try {
                handleResponse(JSON.parse(output || "{}"));
            } catch (e) {
                handleResponse({ "error": I18n.tr("Invalid brightness helper response") });
            }
        }, 0, 6000);
    }

    function updateDeviceBrightnessDisplay(deviceName) {
        brightnessVersion++;
        brightnessChanged();
    }

    Timer {
        id: osdSuppressTimer
        interval: 2000
        running: true
        onTriggered: suppressOsd = false
    }

    Timer {
        id: brightnessCommitTimer
        interval: 120
        repeat: false
        onTriggered: flushBrightnessWrites()
    }

    Component.onCompleted: {
        nightModeEnabled = SessionData.nightModeEnabled;
        deviceBrightnessUserSet = Object.assign({}, SessionData.brightnessUserSetValues);
        rescanDevices();
        if (VGSBackendService.isConnected) {
            checkGammaControlAvailability();
        }
    }

    Timer {
        id: screenChangeRescanTimer
        property int rescanAttempt: 0
        interval: 3000
        repeat: false
        onTriggered: {
            rescanDevices();
            rescanAttempt++;
            if (rescanAttempt < scanRetryLadderAttempts) {
                interval = rescanAttempt === 1 ? 5000 : 8000;
                restart();
                return;
            }
            rescanAttempt = 0;
            interval = 3000;
            osdSuppressTimer.restart();
        }
    }

    // The write entry points gate on brightnessAvailable, so a cleared list
    // cannot be recovered by the successful-write lift; this bounded retry is
    // the only path back on a machine with no hotplug, resume, or backend
    // event. rescanDevices owns the quarantine drop.
    Timer {
        id: scanRecoveryTimer
        interval: 120000
        repeat: false
        onTriggered: rescanDevices()
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            suppressOsd = true;
            liftScanQuarantine();
            screenChangeRescanTimer.rescanAttempt = 0;
            screenChangeRescanTimer.interval = 3000;
            screenChangeRescanTimer.restart();
        }
    }

    Connections {
        target: VGSBackendService

        function onConnectionStateChanged() {
            if (VGSBackendService.isConnected) {
                checkGammaControlAvailability();
            } else {
                gammaControlAvailable = false;
                automationAvailable = false;
            }
        }

        function onCapabilitiesReceived() {
            checkGammaControlAvailability();
        }

        function onGammaStateUpdate(data) {
            root.gammaState = data;
        }
    }

    Connections {
        target: SessionService

        function onSessionResumed() {
            suppressOsd = true;
            osdSuppressTimer.restart();
            liftScanQuarantine();
            resumeRecoveryAttempt = 0;
            resumeRecoveryTimer.interval = 400;
            resumeRecoveryTimer.restart();
        }
    }

    Connections {
        target: SessionData

        function onNightModeEnabledChanged() {
            nightModeEnabled = SessionData.nightModeEnabled;
            evaluateNightMode();
        }

        function onNightModeAutoEnabledChanged() {
            evaluateNightMode();
        }
        function onNightModeAutoModeChanged() {
            evaluateNightMode();
        }
        function onNightModeStartHourChanged() {
            evaluateNightMode();
        }
        function onNightModeStartMinuteChanged() {
            evaluateNightMode();
        }
        function onNightModeEndHourChanged() {
            evaluateNightMode();
        }
        function onNightModeEndMinuteChanged() {
            evaluateNightMode();
        }
        function onNightModeTemperatureChanged() {
            evaluateNightMode();
        }
        function onNightModeHighTemperatureChanged() {
            evaluateNightMode();
        }
        function onLatitudeChanged() {
            evaluateNightMode();
        }
        function onLongitudeChanged() {
            evaluateNightMode();
        }
        function onNightModeUseIPLocationChanged() {
            evaluateNightMode();
        }
    }

    IpcHandler {
        function set(percentage: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available";

            const value = parseInt(percentage);
            if (isNaN(value))
                return "Invalid brightness value: " + percentage;

            const actualDevice = device || root.getPreferredDevice();

            if (actualDevice && !root.devices.some(d => d.id === actualDevice))
                return "Device not found: " + actualDevice;

            const deviceInfo = actualDevice ? root.getCurrentDeviceInfoByName(actualDevice) : null;
            const minValue = (deviceInfo && root.isDisplayBrightnessClass(deviceInfo.class)) ? 1 : 0;
            const clampedValue = Math.max(minValue, Math.min(100, value));

            root.lastIpcDevice = actualDevice;
            if (actualDevice && actualDevice !== root.currentDevice)
                root.setCurrentDevice(actualDevice, false);

            root.setBrightness(clampedValue, actualDevice);

            return actualDevice ? "Brightness set to " + clampedValue + "% on " + actualDevice : "Brightness set to " + clampedValue + "%";
        }

        function increment(step: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available";

            const actualDevice = device || root.getPreferredDevice();

            if (actualDevice && !root.devices.some(d => d.id === actualDevice))
                return "Device not found: " + actualDevice;

            const stepValue = parseInt(step || "5");

            root.lastIpcDevice = actualDevice;
            if (actualDevice && actualDevice !== root.currentDevice)
                root.setCurrentDevice(actualDevice, false);

            const isExponential = SessionData.getBrightnessExponential(actualDevice);
            const currentBrightness = root.getDeviceBrightness(actualDevice);
            const deviceInfo = root.getCurrentDeviceInfoByName(actualDevice);

            const maxValue = isExponential ? 100 : (deviceInfo?.displayMax || 100);
            const newBrightness = Math.min(maxValue, currentBrightness + stepValue);

            root.setBrightness(newBrightness, actualDevice);

            return "Brightness increased by " + stepValue + "%" + (device ? " on " + actualDevice : "");
        }

        function decrement(step: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available";

            const actualDevice = device || root.getPreferredDevice();

            if (actualDevice && !root.devices.some(d => d.id === actualDevice))
                return "Device not found: " + actualDevice;

            const stepValue = parseInt(step || "5");

            root.lastIpcDevice = actualDevice;
            if (actualDevice && actualDevice !== root.currentDevice)
                root.setCurrentDevice(actualDevice, false);

            const isExponential = SessionData.getBrightnessExponential(actualDevice);
            const currentBrightness = root.getDeviceBrightness(actualDevice);
            const deviceInfo = root.getCurrentDeviceInfoByName(actualDevice);

            let minValue = 0;
            switch (true) {
            case isExponential:
                minValue = 1;
                break;
            case deviceInfo && root.isDisplayBrightnessClass(deviceInfo.class):
                minValue = 1;
                break;
            default:
                minValue = 0;
                break;
            }

            const newBrightness = Math.max(minValue, currentBrightness - stepValue);

            root.setBrightness(newBrightness, actualDevice);

            return "Brightness decreased by " + stepValue + "%" + (device ? " on " + actualDevice : "");
        }

        function status(): string {
            if (!root.brightnessAvailable) {
                return "Brightness control not available";
            }

            return "Device: " + root.currentDevice + " - Brightness: " + root.brightnessLevel + "%";
        }

        function list(): string {
            if (!root.brightnessAvailable) {
                return "No brightness devices available";
            }

            let result = "Available devices:\n";
            for (const device of root.devices) {
                const isExp = SessionData.getBrightnessExponential(device.id);
                result += device.id + " (" + device.class + ")" + (isExp ? " [exponential]" : "") + "\n";
            }
            return result;
        }

        function enableExponential(device: string): string {
            const targetDevice = device || root.currentDevice;
            if (!targetDevice) {
                return "No device specified";
            }

            if (!root.devices.some(d => d.id === targetDevice)) {
                return "Device not found: " + targetDevice;
            }

            SessionData.setBrightnessExponential(targetDevice, true);
            return "Exponential mode enabled for " + targetDevice;
        }

        function disableExponential(device: string): string {
            const targetDevice = device || root.currentDevice;
            if (!targetDevice) {
                return "No device specified";
            }

            if (!root.devices.some(d => d.id === targetDevice)) {
                return "Device not found: " + targetDevice;
            }

            SessionData.setBrightnessExponential(targetDevice, false);
            return "Exponential mode disabled for " + targetDevice;
        }

        function toggleExponential(device: string): string {
            const targetDevice = device || root.currentDevice;
            if (!targetDevice) {
                return "No device specified";
            }

            if (!root.devices.some(d => d.id === targetDevice)) {
                return "Device not found: " + targetDevice;
            }

            const currentState = SessionData.getBrightnessExponential(targetDevice);
            SessionData.setBrightnessExponential(targetDevice, !currentState);
            return "Exponential mode " + (!currentState ? "enabled" : "disabled") + " for " + targetDevice;
        }

        target: "brightness"
    }

    IpcHandler {
        function toggle(): string {
            root.toggleNightMode();
            return root.nightModeEnabled ? "Night mode enabled" : "Night mode disabled";
        }

        function enable(): string {
            root.enableNightMode();
            return "Night mode enabled";
        }

        function disable(): string {
            root.disableNightMode();
            return "Night mode disabled";
        }

        function status(): string {
            if (!root.gammaControlAvailable)
                return "Night mode: unavailable (no gamma control)";

            const parts = ["Night mode: " + (root.nightModeEnabled ? "enabled" : "disabled")];

            if (root.gammaCurrentTemp > 0)
                parts.push("Current temperature: " + root.gammaCurrentTemp + "K");

            parts.push("Target night temperature: " + SessionData.nightModeTemperature + "K");

            if (SessionData.nightModeAutoEnabled) {
                parts.push("Target day temperature: " + SessionData.nightModeHighTemperature + "K");
                parts.push("Automation: " + SessionData.nightModeAutoMode);
                parts.push("Period: " + (root.gammaIsDay ? "day" : "night"));

                if (root.gammaNextTransition)
                    parts.push("Next transition: " + root.gammaNextTransition);
                if (root.gammaSunriseTime)
                    parts.push("Sunrise: " + root.gammaSunriseTime);
                if (root.gammaSunsetTime)
                    parts.push("Sunset: " + root.gammaSunsetTime);
            }

            return parts.join("\n");
        }

        function getCurrentTemp(): string {
            if (!root.gammaControlAvailable)
                return "Gamma control not available";
            if (root.gammaCurrentTemp <= 0)
                return "No current temperature reported";
            return root.gammaCurrentTemp.toString();
        }

        function getTargetTemp(): string {
            return SessionData.nightModeTemperature.toString();
        }

        function getDayTemp(): string {
            return SessionData.nightModeHighTemperature.toString();
        }

        function setTargetTemp(value: string): string {
            if (!value)
                return "Usage: night setTargetTemp <2500-6000>";

            const temp = parseInt(value);
            if (isNaN(temp))
                return "Invalid temperature: " + value;
            if (temp < 2500 || temp > 6000)
                return "Temperature must be between 2500K and 6000K";

            const rounded = Math.round(temp / 500) * 500;
            SessionData.setNightModeTemperature(rounded);

            if (root.nightModeEnabled) {
                switch (true) {
                case SessionData.nightModeAutoEnabled:
                    root.startAutomation();
                    break;
                default:
                    root.applyNightModeDirectly();
                    break;
                }
            }

            if (rounded !== temp)
                return "Night temperature set to " + rounded + "K (rounded from " + temp + "K)";
            return "Night temperature set to " + rounded + "K";
        }

        function setDayTemp(value: string): string {
            if (!value)
                return "Usage: night setDayTemp <2500-6500>";

            const temp = parseInt(value);
            if (isNaN(temp))
                return "Invalid temperature: " + value;
            if (temp < 2500 || temp > 6500)
                return "Temperature must be between 2500K and 6500K";

            const rounded = Math.round(temp / 500) * 500;
            SessionData.setNightModeHighTemperature(rounded);

            if (root.nightModeEnabled && SessionData.nightModeAutoEnabled)
                root.startAutomation();

            if (rounded !== temp)
                return "Day temperature set to " + rounded + "K (rounded from " + temp + "K)";
            return "Day temperature set to " + rounded + "K";
        }

        function getSchedule(): string {
            if (!SessionData.nightModeAutoEnabled)
                return "Automation disabled";

            const parts = ["Mode: " + SessionData.nightModeAutoMode];
            parts.push("Period: " + (root.gammaIsDay ? "day" : "night"));

            if (root.gammaDawnTime)
                parts.push("Dawn: " + root.gammaDawnTime);
            if (root.gammaSunriseTime)
                parts.push("Sunrise: " + root.gammaSunriseTime);
            if (root.gammaSunsetTime)
                parts.push("Sunset: " + root.gammaSunsetTime);
            if (root.gammaNightTime)
                parts.push("Night: " + root.gammaNightTime);
            if (root.gammaNextTransition)
                parts.push("Next transition: " + root.gammaNextTransition);
            if (root.gammaSunPosition > 0)
                parts.push("Sun position: " + root.gammaSunPosition.toFixed(2) + "°");

            return parts.join("\n");
        }

        target: "night"
    }
}
