pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.Services

Singleton {
    id: root

    readonly property BluetoothAdapter adapter: Bluetooth.defaultAdapter
    readonly property bool available: adapter !== null
    readonly property bool enabled: (adapter && adapter.enabled) ?? false
    readonly property bool discovering: (adapter && adapter.discovering) ?? false
    readonly property var devices: adapter ? adapter.devices : null
    readonly property bool enhancedPairingAvailable: VGSBackendService.isConnected && VGSBackendService.capabilities.includes("bluetooth") && VGSBackendService.methods.includes("bluetooth.pair") && VGSBackendService.methods.includes("bluetooth.pairing.submit")
    readonly property bool connected: {
        if (!adapter || !adapter.devices) {
            return false;
        }

        let isConnected = false;
        adapter.devices.values.forEach(dev => {
            if (dev.connected)
                isConnected = true;
        });
        return isConnected;
    }
    readonly property bool connecting: {
        if (!adapter || !adapter.devices) {
            return false;
        }

        let busy = false;
        adapter.devices.values.forEach(dev => {
            if (!dev)
                return;
            if (dev.pairing || dev.state === BluetoothDeviceState.Connecting)
                busy = true;
        });
        return busy;
    }
    readonly property var pairedDevices: {
        if (!adapter || !adapter.devices) {
            return [];
        }

        return adapter.devices.values.filter(dev => {
            return dev && (dev.paired || dev.trusted);
        });
    }
    readonly property var allDevicesWithBattery: {
        if (!adapter || !adapter.devices) {
            return [];
        }

        return adapter.devices.values.filter(dev => {
            return dev && dev.batteryAvailable && dev.battery > 0;
        });
    }

    function sortDevices(devices) {
        return devices.sort((a, b) => {
            const aName = a.name || a.deviceName || "";
            const bName = b.name || b.deviceName || "";
            const aAddr = a.address || "";
            const bAddr = b.address || "";

            const aHasRealName = aName.includes(" ") && aName.length > 3;
            const bHasRealName = bName.includes(" ") && bName.length > 3;

            if (aHasRealName && !bHasRealName)
                return -1;
            if (!aHasRealName && bHasRealName)
                return 1;

            if (aHasRealName && bHasRealName) {
                return aName.localeCompare(bName);
            }

            return aAddr.localeCompare(bAddr);
        });
    }

    function getDeviceIcon(device) {
        if (!device) {
            return "bluetooth";
        }

        const name = (device.name || device.deviceName || "").toLowerCase();
        const icon = (device.icon || "").toLowerCase();

        const audioKeywords = ["headset", "audio", "headphone", "airpod", "arctis"];
        if (audioKeywords.some(keyword => icon.includes(keyword) || name.includes(keyword))) {
            return "headset";
        }

        if (icon.includes("mouse") || name.includes("mouse")) {
            return "mouse";
        }

        if (icon.includes("keyboard") || name.includes("keyboard")) {
            return "keyboard";
        }

        const phoneKeywords = ["phone", "iphone", "android", "samsung"];
        if (phoneKeywords.some(keyword => icon.includes(keyword) || name.includes(keyword))) {
            return "smartphone";
        }

        if (icon.includes("watch") || name.includes("watch")) {
            return "watch";
        }

        if (icon.includes("speaker") || name.includes("speaker")) {
            return "speaker";
        }

        if (icon.includes("display") || name.includes("tv")) {
            return "tv";
        }

        return "bluetooth";
    }

    function canConnect(device) {
        if (!device) {
            return false;
        }

        return !device.paired && !device.pairing && !device.blocked;
    }

    function getSignalStrength(device) {
        if (!device || device.signalStrength === undefined || device.signalStrength <= 0) {
            return "Unknown";
        }

        const signal = device.signalStrength;
        if (signal >= 80) {
            return "Excellent";
        }
        if (signal >= 60) {
            return "Good";
        }
        if (signal >= 40) {
            return "Fair";
        }
        if (signal >= 20) {
            return "Poor";
        }

        return "Very Poor";
    }

    function getSignalIcon(device) {
        if (!device || device.signalStrength === undefined || device.signalStrength <= 0) {
            return "signal_cellular_null";
        }

        const signal = device.signalStrength;
        if (signal >= 80) {
            return "signal_cellular_4_bar";
        }
        if (signal >= 60) {
            return "signal_cellular_3_bar";
        }
        if (signal >= 40) {
            return "signal_cellular_2_bar";
        }
        if (signal >= 20) {
            return "signal_cellular_1_bar";
        }

        return "signal_cellular_0_bar";
    }

    function isDeviceBusy(device) {
        if (!device) {
            return false;
        }
        return device.pairing || device.state === BluetoothDeviceState.Disconnecting || device.state === BluetoothDeviceState.Connecting;
    }

    // Serializes audio-device handoff. Many BT adapters can only hold one
    // A2DP link at a time, so asking to connect a second audio device while
    // another is connected makes BlueZ's Connect() fail silently (no UI
    // feedback). We disconnect the other audio device(s) first, wait for them
    // to actually drop, then connect the target.
    property var pendingConnectDevice: null
    property var pendingDisconnectDevices: []

    readonly property bool pendingDisconnectsCleared: {
        if (!pendingConnectDevice)
            return false;
        return pendingDisconnectDevices.every(dev => !dev || !dev.connected);
    }

    onPendingDisconnectsClearedChanged: {
        if (pendingDisconnectsCleared)
            finishPendingConnect();
    }

    // Best-effort fallback: if a disconnect never reports completion, connect
    // the target anyway rather than leaving the request stuck.
    Timer {
        id: pendingConnectTimer
        interval: 4000
        repeat: false
        onTriggered: root.finishPendingConnect()
    }

    function connectDeviceWithTrust(device) {
        if (!device) {
            return;
        }

        device.trusted = true;

        if (isAudioDevice(device) && adapter && adapter.devices) {
            const others = adapter.devices.values.filter(dev => {
                return dev && dev.address !== device.address && dev.connected && isAudioDevice(dev);
            });
            if (others.length > 0) {
                // Assign the disconnect list before the target so the
                // pendingDisconnectsCleared binding never sees an empty list
                // (which would read as "already cleared").
                pendingDisconnectDevices = others;
                pendingConnectDevice = device;
                others.forEach(dev => dev.disconnect());
                pendingConnectTimer.restart();
                return;
            }
        }

        performConnect(device);
    }

    function finishPendingConnect() {
        const device = pendingConnectDevice;
        if (!device) {
            return;
        }
        pendingConnectTimer.stop();
        pendingConnectDevice = null;
        pendingDisconnectDevices = [];
        performConnect(device);
    }

    function performConnect(device) {
        if (!device) {
            return;
        }
        device.connect();
        // Standard single-output UX: make the freshly connected audio device
        // the default sink once its Pipewire node shows up.
        if (isAudioDevice(device)) {
            AudioService.switchSinkToBluetoothDevice(device.address);
        }
    }

    function pairDevice(device, callback) {
        if (!device) {
            if (callback)
                callback({
                    error: "Invalid device"
                });
            return;
        }

        // The VGS backend actually implements a bluez agent, so we can pair anything
        if (enhancedPairingAvailable) {
            const devicePath = getDevicePath(device);
            VGSBackendService.bluetoothPair(devicePath, callback);
            return;
        }

        // Quickshell does not implement a bluez agent, so we can try to pair but only with devices that don't require a passcode
        device.trusted = true;
        device.connect();
        if (callback)
            callback({
                success: true
            });
    }

    function getCardName(device) {
        if (!device) {
            return "";
        }
        return `bluez_card.${device.address.replace(/:/g, "_")}`;
    }

    function getDevicePath(device) {
        if (!device || !device.address) {
            return "";
        }
        // Quickshell devices expose their real D-Bus path; use it so backend
        // pairing works on systems whose default adapter is not hci0.
        if (device.dbusPath) {
            return device.dbusPath;
        }
        const adapterPath = (adapter && adapter.dbusPath) ? adapter.dbusPath : "/org/bluez/hci0";
        return `${adapterPath}/dev_${device.address.replace(/:/g, "_")}`;
    }

    function isAudioDevice(device) {
        if (!device) {
            return false;
        }
        const icon = getDeviceIcon(device);
        return icon === "headset" || icon === "speaker";
    }

    function getCodecInfo(codecName) {
        const codec = codecName.replace(/[-\s]+/g, "_").toUpperCase();

        const codecMap = {
            "LDAC": {
                "name": "LDAC",
                "description": "Highest quality • Higher battery usage",
                "qualityRole": "success"
            },
            "APTX_HD": {
                "name": "aptX HD",
                "description": "High quality • Balanced battery",
                "qualityRole": "warning"
            },
            "APTX": {
                "name": "aptX",
                "description": "Good quality • Low latency",
                "qualityRole": "warning"
            },
            "AAC": {
                "name": "AAC",
                "description": "Balanced quality and battery",
                "qualityRole": "info"
            },
            "SBC_XQ": {
                "name": "SBC-XQ",
                "description": "Enhanced SBC • Better compatibility",
                "qualityRole": "info"
            },
            "SBC": {
                "name": "SBC",
                "description": "Basic quality • Universal compatibility",
                "qualityRole": "muted"
            },
            "MSBC": {
                "name": "mSBC",
                "description": "Modified SBC • Optimized for speech",
                "qualityRole": "muted"
            },
            "CVSD": {
                "name": "CVSD",
                "description": "Basic speech codec • Legacy compatibility",
                "qualityRole": "muted"
            }
        };

        return codecMap[codec] || {
            "name": codecName,
            "description": "Unknown codec",
            "qualityRole": "muted"
        };
    }

    property var deviceCodecs: ({})

    function updateDeviceCodec(deviceAddress, codec) {
        deviceCodecs[deviceAddress] = codec;
        deviceCodecsChanged();
    }

    function refreshDeviceCodec(device) {
        if (!device || !device.connected || !isAudioDevice(device)) {
            return;
        }

        const cardName = getCardName(device);
        codecQueryProcess.cardName = cardName;
        codecQueryProcess.deviceAddress = device.address;
        codecQueryProcess.availableCodecs = [];
        codecQueryProcess.parsingTargetCard = false;
        codecQueryProcess.detectedCodec = "";
        codecQueryProcess.running = true;
    }

    function getCurrentCodec(device, callback) {
        if (!device || !device.connected || !isAudioDevice(device)) {
            callback("");
            return;
        }

        const cardName = getCardName(device);
        codecQueryProcess.cardName = cardName;
        codecQueryProcess.callback = callback;
        codecQueryProcess.availableCodecs = [];
        codecQueryProcess.parsingTargetCard = false;
        codecQueryProcess.detectedCodec = "";
        codecQueryProcess.running = true;
    }

    function getAvailableCodecs(device, callback) {
        if (!device || !device.connected || !isAudioDevice(device)) {
            callback([], "");
            return;
        }

        const cardName = getCardName(device);
        codecFullQueryProcess.cardName = cardName;
        codecFullQueryProcess.callback = callback;
        codecFullQueryProcess.availableCodecs = [];
        codecFullQueryProcess.parsingTargetCard = false;
        codecFullQueryProcess.detectedCodec = "";
        codecFullQueryProcess.running = true;
    }

    function switchCodec(device, profileName, callback) {
        if (!device || !isAudioDevice(device)) {
            callback(false, "Invalid device");
            return;
        }

        const cardName = getCardName(device);
        codecSwitchProcess.cardName = cardName;
        codecSwitchProcess.profile = profileName;
        codecSwitchProcess.callback = callback;
        codecSwitchProcess.running = true;
    }

    Process {
        id: codecQueryProcess

        property string cardName: ""
        property string deviceAddress: ""
        property var callback: null
        property bool parsingTargetCard: false
        property string detectedCodec: ""
        property var availableCodecs: []

        command: ["pactl", "list", "cards"]

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && detectedCodec) {
                if (deviceAddress) {
                    root.updateDeviceCodec(deviceAddress, detectedCodec);
                }
                if (callback) {
                    callback(detectedCodec);
                }
            } else if (callback) {
                callback("");
            }

            parsingTargetCard = false;
            detectedCodec = "";
            availableCodecs = [];
            deviceAddress = "";
            callback = null;
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                let line = data.trim();

                if (line.includes(`Name: ${codecQueryProcess.cardName}`)) {
                    codecQueryProcess.parsingTargetCard = true;
                    return;
                }

                if (codecQueryProcess.parsingTargetCard && line.startsWith("Name: ") && !line.includes(codecQueryProcess.cardName)) {
                    codecQueryProcess.parsingTargetCard = false;
                    return;
                }

                if (codecQueryProcess.parsingTargetCard) {
                    if (line.startsWith("Active Profile:")) {
                        let profile = line.split(": ")[1] || "";
                        let activeCodec = codecQueryProcess.availableCodecs.find(c => {
                            return c.profile === profile;
                        });
                        if (activeCodec) {
                            codecQueryProcess.detectedCodec = activeCodec.name;
                        }
                        return;
                    }
                    if (line.includes("codec") && line.includes("available: yes")) {
                        let parts = line.split(": ");
                        if (parts.length >= 2) {
                            let profile = parts[0].trim();
                            let description = parts[1];
                            let codecMatch = description.match(/codec ([^\)]+)\)/i);
                            let codecName = codecMatch ? codecMatch[1].trim().toUpperCase() : "UNKNOWN";
                            let codecInfo = root.getCodecInfo(codecName);
                            if (codecInfo && !codecQueryProcess.availableCodecs.some(c => {
                                return c.profile === profile;
                            })) {
                                let newCodecs = codecQueryProcess.availableCodecs.slice();
                                newCodecs.push({
                                    "name": codecInfo.name,
                                    "profile": profile,
                                    "description": codecInfo.description,
                                    "qualityRole": codecInfo.qualityRole || "muted"
                                });
                                codecQueryProcess.availableCodecs = newCodecs;
                            }
                        }
                    }
                }
            }
        }
    }

    Process {
        id: codecFullQueryProcess

        property string cardName: ""
        property var callback: null
        property bool parsingTargetCard: false
        property string detectedCodec: ""
        property var availableCodecs: []

        command: ["pactl", "list", "cards"]

        onExited: function (exitCode, exitStatus) {
            if (callback) {
                callback(exitCode === 0 ? availableCodecs : [], exitCode === 0 ? detectedCodec : "");
            }
            parsingTargetCard = false;
            detectedCodec = "";
            availableCodecs = [];
            callback = null;
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                let line = data.trim();

                if (line.includes(`Name: ${codecFullQueryProcess.cardName}`)) {
                    codecFullQueryProcess.parsingTargetCard = true;
                    return;
                }

                if (codecFullQueryProcess.parsingTargetCard && line.startsWith("Name: ") && !line.includes(codecFullQueryProcess.cardName)) {
                    codecFullQueryProcess.parsingTargetCard = false;
                    return;
                }

                if (codecFullQueryProcess.parsingTargetCard) {
                    if (line.startsWith("Active Profile:")) {
                        let profile = line.split(": ")[1] || "";
                        let activeCodec = codecFullQueryProcess.availableCodecs.find(c => {
                            return c.profile === profile;
                        });
                        if (activeCodec) {
                            codecFullQueryProcess.detectedCodec = activeCodec.name;
                        }
                        return;
                    }
                    if (line.includes("codec") && line.includes("available: yes")) {
                        let parts = line.split(": ");
                        if (parts.length >= 2) {
                            let profile = parts[0].trim();
                            let description = parts[1];
                            let codecMatch = description.match(/codec ([^\)]+)\)/i);
                            let codecName = codecMatch ? codecMatch[1].trim().toUpperCase() : "UNKNOWN";
                            let codecInfo = root.getCodecInfo(codecName);
                            if (codecInfo && !codecFullQueryProcess.availableCodecs.some(c => {
                                return c.profile === profile;
                            })) {
                                let newCodecs = codecFullQueryProcess.availableCodecs.slice();
                                newCodecs.push({
                                    "name": codecInfo.name,
                                    "profile": profile,
                                    "description": codecInfo.description,
                                    "qualityRole": codecInfo.qualityRole || "muted"
                                });
                                codecFullQueryProcess.availableCodecs = newCodecs;
                            }
                        }
                    }
                }
            }
        }
    }

    Process {
        id: codecSwitchProcess

        property string cardName: ""
        property string profile: ""
        property var callback: null

        command: ["pactl", "set-card-profile", cardName, profile]

        onExited: function (exitCode, exitStatus) {
            if (callback) {
                callback(exitCode === 0, exitCode === 0 ? "Codec switched successfully" : "Failed to switch codec");
            }

            // If successful, refresh the codec for this device
            if (exitCode === 0) {
                if (root.adapter && root.adapter.devices) {
                    root.adapter.devices.values.forEach(device => {
                        if (device && root.getCardName(device) === cardName) {
                            Qt.callLater(() => root.refreshDeviceCodec(device));
                        }
                    });
                }
            }

            callback = null;
        }
    }
}
