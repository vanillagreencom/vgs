pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("VGSBackendService")

    property bool backendAvailable: false
    property var capabilities: []
    property var methods: []
    property int apiVersion: 0
    property int vgsApiVersion: 0
    property string cliVersion: ""
    property string lastError: ""
    // VGS protocol compatibility is tracked via vgsApiVersion, not the
    // upstream-compatible apiVersion ordinal (which stays truthful and may be 0
    // while only VGS-native methods are implemented).
    readonly property int expectedVgsApiVersion: 1
    property var availablePlugins: []
    property var installedPlugins: []
    // Derived from the request socket's live link state so it can never drift
    // from reality (an imperatively-assigned bool was observed reverting under
    // heavy binding load). Everything else reads this; nothing writes it.
    readonly property bool isConnected: requestSocket.linkUp
    property bool isConnecting: false
    property bool subscribeConnected: false

    // Feature availability is gated on advertised capabilities, not on the bare
    // connection: the backend may be connected while only advertising a subset
    // of services (e.g. "core"). UI must use these, not backendAvailable alone.
    readonly property bool pluginsAvailable: isConnected && capabilities.includes("plugins")

    // Live backend socket, exported by the runner (`vshell run`). Empty when the
    // backend is disabled or unavailable; both sockets stay idle in that case so
    // there is no reconnect churn against a path that will never exist.
    readonly property string socketPath: Quickshell.env("VGS_SOCKET") || ""
    readonly property string backendBuildLogPath: (Quickshell.env("XDG_CACHE_HOME") || ((Quickshell.env("HOME") || "") + "/.cache")) + "/vshell/backend-build.log"

    property var pendingRequests: ({})
    property var pendingRequestMethods: ({})
    property var pendingRequestTimes: ({})
    property var clipboardRequestIds: ({})
    property int requestIdCounter: 0
    property bool shownOutdatedError: false

    // A wedged-but-connected backend must not strand callers forever: their
    // UI flags (wifiToggling, creatingPrinter, ...) only clear on a response.
    // Budget must exceed the slowest legitimate call (sysupdate.refresh runs
    // up to 2 minutes).
    readonly property int requestTimeoutMs: 150000

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root._sweepPendingRequests()
    }

    function _sweepPendingRequests() {
        const now = Date.now();
        for (const id in pendingRequests) {
            if (now - (pendingRequestTimes[id] || now) <= requestTimeoutMs)
                continue;
            const cb = pendingRequests[id];
            const method = pendingRequestMethods[id] || "";
            delete pendingRequests[id];
            delete pendingRequestMethods[id];
            delete pendingRequestTimes[id];
            delete clipboardRequestIds[id];
            log.warn("Backend request timed out:", method);
            if (cb)
                cb({
                    "error": "VGS backend request timed out"
                });
        }
    }

    signal pluginsListReceived(var plugins)
    signal installedPluginsReceived(var plugins)
    signal searchResultsReceived(var plugins)
    signal operationSuccess(string message)
    signal operationError(string error)
    signal connectionStateChanged

    signal networkStateUpdate(var data)
    signal cupsStateUpdate(var data)
    signal loginctlStateUpdate(var data)
    signal capabilitiesReceived
    signal credentialsRequest(var data)
    signal bluetoothPairingRequest(var data)
    signal wlrOutputStateUpdate(var data)
    signal evdevStateUpdate(var data)
    signal gammaStateUpdate(var data)
    signal wallpaperCycleUpdate(var data)
    signal openUrlRequested(string url)
    signal appPickerRequested(var data)
    signal screensaverStateUpdate(var data)
    signal freedesktopStateUpdate(var data)
    signal clipboardStateUpdate(var data)
    signal locationStateUpdate(var data)
    signal sysupdateStateUpdate(var data)
    signal tailscaleStateUpdate(var data)

    property bool capsLockState: false
    property bool screensaverInhibited: false
    property var screensaverInhibitors: []

    property var activeSubscriptions: ["network", "network.credentials", "loginctl", "freedesktop", "freedesktop.screensaver", "gamma", "wallpaper", "bluetooth", "bluetooth.pairing", "wlroutput", "evdev", "browser", "browser.open_requested", "dbus", "clipboard", "location", "sysupdate"]

    Component.onCompleted: {
        backendAvailable = false;
        capabilities = [];
        methods = [];
    }

    VgsSocket {
        id: requestSocket
        path: root.socketPath
        connected: root.socketPath.length > 0

        onConnectionStateChanged: {
            if (linkUp) {
                root.isConnecting = false;
                root.connectionStateChanged();
                subscribeSocket.connected = true;
            } else {
                // Guard the log/flush on backendAvailable so reconnect-failure
                // events (which re-fire with the link already down) don't spam.
                if (root.backendAvailable)
                    log.warn("VGS backend disconnected");
                root.isConnecting = false;
                root.backendAvailable = false;
                root.lastError = "VGS backend disconnected";
                root.apiVersion = 0;
                root.vgsApiVersion = 0;
                root.capabilities = [];
                root.methods = [];
                // Backend-fed live state must not survive the backend: a
                // stale inhibitor would block auto-lock/DPMS forever.
                root.screensaverInhibited = false;
                root.screensaverInhibitors = [];
                root.capsLockState = false;
                root._flushPending("VGS backend disconnected");
                root.connectionStateChanged();
            }
        }

        parser: SplitParser {
            onRead: line => {
                if (!line || line.length === 0)
                    return;

                let response;
                try {
                    response = JSON.parse(line);
                } catch (e) {
                    log.warn("Failed to parse request response:", line.substring(0, 100));
                    return;
                }
                const isClipboard = clipboardRequestIds[response.id];
                if (isClipboard)
                    delete clipboardRequestIds[response.id];
                else
                    log.debug("Request socket << id=" + response.id + " method=" + (pendingRequestMethods[response.id] || "") + (response.error ? " error" : " ok"));
                handleResponse(response);
            }
        }
    }

    VgsSocket {
        id: subscribeSocket
        path: root.socketPath
        connected: false

        onConnectionStateChanged: {
            root.subscribeConnected = linkUp;
            if (linkUp) {
                sendSubscribeRequest();
            }
        }

        parser: SplitParser {
            onRead: line => {
                if (!line || line.length === 0)
                    return;

                let response;
                try {
                    response = JSON.parse(line);
                } catch (e) {
                    log.warn("Failed to parse subscription event:", line.substring(0, 100));
                    return;
                }
                if (response.result && response.result.service && response.result.service !== "clipboard")
                    log.debug("Subscribe socket << service=" + response.result.service);
                handleSubscriptionEvent(response);
            }
        }
    }

    function sendSubscribeRequest() {
        const request = {
            "method": "subscribe"
        };

        if (activeSubscriptions.length > 0) {
            request.params = {
                "services": activeSubscriptions
            };
            log.debug("Subscribing to services:", JSON.stringify(activeSubscriptions));
        } else {
            log.debug("Subscribing to all services");
        }

        subscribeSocket.send(request);
    }

    function subscribe(services) {
        if (!Array.isArray(services)) {
            services = [services];
        }

        activeSubscriptions = services;

        // The server replaces this connection's subscription set on a repeat
        // subscribe, so re-send over the live socket. Bouncing the socket
        // instead would open a gap where broadcasts — including one-shot
        // credential/pairing prompts — are lost.
        if (subscribeConnected) {
            sendSubscribeRequest();
        }
    }

    function addSubscription(service) {
        if (activeSubscriptions.includes("all"))
            return;
        if (!activeSubscriptions.includes(service)) {
            const newSubs = [...activeSubscriptions, service];
            subscribe(newSubs);
        }
    }

    function removeSubscription(service) {
        if (activeSubscriptions.includes("all")) {
            const allServices = ["network", "loginctl", "freedesktop", "gamma", "bluetooth", "browser", "location"];
            const filtered = allServices.filter(s => s !== service);
            subscribe(filtered);
        } else {
            const filtered = activeSubscriptions.filter(s => s !== service);
            if (filtered.length === 0) {
                log.warn("Cannot remove last subscription");
                return;
            }
            subscribe(filtered);
        }
    }

    function subscribeAll() {
        subscribe(["all"]);
    }

    function subscribeAllExcept(excludeServices) {
        if (!Array.isArray(excludeServices)) {
            excludeServices = [excludeServices];
        }

        const allServices = ["network", "loginctl", "freedesktop", "gamma", "bluetooth", "cups", "browser", "dbus", "location"];
        const filtered = allServices.filter(s => !excludeServices.includes(s));
        subscribe(filtered);
    }

    function handleSubscriptionEvent(response) {
        if (response.error) {
            const errText = typeof response.error === "string" ? response.error : JSON.stringify(response.error);
            if (errText.includes("unknown method") && errText.includes("subscribe")) {
                if (!shownOutdatedError) {
                    log.error("Server does not support subscribe method");
                    ToastService.showError(I18n.tr("VGS backend unavailable"));
                    shownOutdatedError = true;
                }
            }
            return;
        }

        if (!response.result) {
            return;
        }

        const service = response.result.service;
        const data = response.result.data;
        if (data === undefined || data === null) {
            return;
        }

        if (service === "server") {
            // The server frame arrives on every (re)subscribe; only announce
            // capabilities when they actually changed, otherwise every
            // popout-driven resubscribe re-runs the listeners' setup calls.
            const wasAvailable = backendAvailable;
            const prevInventory = JSON.stringify(capabilities) + "|" + JSON.stringify(methods);
            apiVersion = data.apiVersion || 0;
            vgsApiVersion = data.vgsApiVersion || 0;
            cliVersion = data.cliVersion || "";
            capabilities = data.capabilities || [];
            methods = data.methods || [];
            backendAvailable = true;
            lastError = "";

            if (vgsApiVersion < expectedVgsApiVersion && !shownOutdatedError) {
                shownOutdatedError = true;
                ToastService.showError(I18n.tr("VGS backend is outdated (protocol v%1, expected v%2)").arg(vgsApiVersion).arg(expectedVgsApiVersion));
            }

            const newInventory = JSON.stringify(capabilities) + "|" + JSON.stringify(methods);
            if (!wasAvailable || newInventory !== prevInventory) {
                log.info("Connected (API v" + apiVersion + ", VGS v" + vgsApiVersion + ", CLI " + cliVersion + ") -", JSON.stringify(capabilities));
                capabilitiesReceived();
            }
        } else if (service === "network") {
            networkStateUpdate(data);
        } else if (service === "network.credentials") {
            credentialsRequest(data);
        } else if (service === "loginctl") {
            loginctlStateUpdate(data);
        } else if (service === "bluetooth.pairing") {
            bluetoothPairingRequest(data);
        } else if (service === "cups") {
            cupsStateUpdate(data);
        } else if (service === "wlroutput") {
            wlrOutputStateUpdate(data);
        } else if (service === "evdev") {
            if (data.capsLock !== undefined) {
                capsLockState = data.capsLock;
            }
            evdevStateUpdate(data);
        } else if (service === "gamma") {
            gammaStateUpdate(data);
        } else if (service === "wallpaper") {
            wallpaperCycleUpdate(data);
        } else if (service === "browser.open_requested") {
            if (data.target) {
                if (data.requestType === "url" || !data.requestType) {
                    openUrlRequested(data.target);
                } else {
                    appPickerRequested(data);
                }
            } else if (data.url) {
                openUrlRequested(data.url);
            }
        } else if (service === "freedesktop.screensaver") {
            screensaverInhibited = data.inhibited || false;
            screensaverInhibitors = data.inhibitors || [];
            screensaverStateUpdate(data);
        } else if (service === "freedesktop") {
            freedesktopStateUpdate(data);
        } else if (service === "dbus") {
            dbusSignalReceived(data.subscriptionId || "", data);
        } else if (service === "clipboard") {
            clipboardStateUpdate(data);
        } else if (service === "location") {
            locationStateUpdate(data);
        } else if (service === "sysupdate") {
            sysupdateStateUpdate(data);
        } else if (service === "tailscale") {
            tailscaleStateUpdate(data);
        }
    }

    function sendVgsClipboardRequest(method, params, callback) {
        requestIdCounter++;
        const id = "vgs-clipboard-" + Date.now() + "-" + requestIdCounter;
        const payload = JSON.stringify(params || {});
        Proc.runCommand(id, [Paths.vshellCli, "clipboard", "rpc", method, payload, "--json"], function(output, exitCode, stderr) {
            let response = {};
            try {
                response = JSON.parse(output || "{}");
            } catch (e) {
                response = { "error": stderr || ("invalid VGS clipboard response: " + e) };
            }
            if (exitCode !== 0 && !response.error)
                response.error = stderr || "VGS clipboard command failed";
            if (callback)
                callback(response);
        }, 0, 15000);
    }

    function sendRequest(method, params, callback) {
        if (method && method.startsWith("clipboard") && !(isConnected && methods.includes(method))) {
            sendVgsClipboardRequest(method, params, callback);
            return;
        }

        if (!isConnected) {
            log.warn("VGSBackendService.sendRequest: Not connected, method:", method);
            lastError = "VGS backend unavailable";
            if (callback) {
                callback({
                    "error": "VGS backend unavailable"
                });
            }
            return;
        }

        requestIdCounter++;
        const id = Date.now() + requestIdCounter;
        const request = {
            "id": id,
            "method": method
        };

        if (params) {
            request.params = params;
        }

        pendingRequestMethods[id] = method;
        pendingRequestTimes[id] = Date.now();
        if (callback)
            pendingRequests[id] = callback;

        if (method.startsWith("clipboard")) {
            clipboardRequestIds[id] = true;
        } else {
            log.debug("VGSBackendService.sendRequest: Sending request id=" + id + " method=" + method);
        }
        requestSocket.send(request);
    }

    function handleResponse(response) {
        const callback = pendingRequests[response.id];
        const method = pendingRequestMethods[response.id] || "";
        delete pendingRequestMethods[response.id];
        delete pendingRequestTimes[response.id];

        if (callback) {
            delete pendingRequests[response.id];
            callback(response);
        } else if (response.error) {
            lastError = response.error;
            if (method && !method.startsWith("clipboard"))
                log.warn("Unhandled backend error for " + method + ": " + response.error);
        }
    }

    // Reject every in-flight request when the socket drops so callers waiting on
    // a response are not stranded forever. Called from the request socket's
    // disconnect handler.
    function _flushPending(reason) {
        const pending = pendingRequests;
        pendingRequests = ({});
        pendingRequestMethods = ({});
        pendingRequestTimes = ({});
        clipboardRequestIds = ({});
        for (const id in pending) {
            const cb = pending[id];
            if (cb)
                cb({
                    "error": reason || "VGS backend disconnected"
                });
        }
    }

    function ping(callback) {
        sendRequest("ping", null, callback);
    }

    function listPlugins(callback) {
        sendRequest("plugins.list", null, response => {
            if (response.result) {
                availablePlugins = response.result;
                pluginsListReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function listInstalled(callback) {
        sendRequest("plugins.listInstalled", null, response => {
            if (response.result) {
                installedPlugins = response.result;
                installedPluginsReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function search(query, category, compositor, capability, callback) {
        const params = {
            "query": query
        };
        if (category) {
            params.category = category;
        }
        if (compositor) {
            params.compositor = compositor;
        }
        if (capability) {
            params.capability = capability;
        }

        sendRequest("plugins.search", params, response => {
            if (response.result) {
                searchResultsReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function install(pluginName, callback) {
        sendRequest("plugins.install", {
            "name": pluginName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalled();
            }
        });
    }

    function uninstall(pluginName, callback) {
        sendRequest("plugins.uninstall", {
            "name": pluginName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalled();
            }
        });
    }

    function update(pluginName, callback) {
        sendRequest("plugins.update", {
            "name": pluginName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalled();
            }
        });
    }

    function lockSession(callback) {
        sendRequest("loginctl.lock", null, callback);
    }

    function unlockSession(callback) {
        sendRequest("loginctl.unlock", null, callback);
    }

    function setLockedHint(locked, callback) {
        sendRequest("loginctl.setLockedHint", {
            "locked": locked
        }, callback);
    }

    function bluetoothPair(devicePath, callback) {
        sendRequest("bluetooth.pair", {
            "device": devicePath
        }, callback);
    }

    function bluetoothConnect(devicePath, callback) {
        sendRequest("bluetooth.connect", {
            "device": devicePath
        }, callback);
    }

    function bluetoothDisconnect(devicePath, callback) {
        sendRequest("bluetooth.disconnect", {
            "device": devicePath
        }, callback);
    }

    function bluetoothRemove(devicePath, callback) {
        sendRequest("bluetooth.remove", {
            "device": devicePath
        }, callback);
    }

    function bluetoothTrust(devicePath, callback) {
        sendRequest("bluetooth.trust", {
            "device": devicePath
        }, callback);
    }

    function bluetoothSubmitPairing(token, secrets, accept, callback) {
        sendRequest("bluetooth.pairing.submit", {
            "token": token,
            "secrets": secrets,
            "accept": accept
        }, callback);
    }

    function bluetoothCancelPairing(token, callback) {
        sendRequest("bluetooth.pairing.cancel", {
            "token": token
        }, callback);
    }

    signal dbusSignalReceived(string subscriptionId, var data)

    property var dbusSubscriptions: ({})

    function dbusCall(bus, dest, path, iface, method, args, callback) {
        sendRequest("dbus.call", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "method": method,
            "args": args || []
        }, callback);
    }

    function dbusGetProperty(bus, dest, path, iface, property, callback) {
        sendRequest("dbus.getProperty", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "property": property
        }, callback);
    }

    function dbusSetProperty(bus, dest, path, iface, property, value, callback) {
        sendRequest("dbus.setProperty", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "property": property,
            "value": value
        }, callback);
    }

    function dbusGetAllProperties(bus, dest, path, iface, callback) {
        sendRequest("dbus.getAllProperties", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface
        }, callback);
    }

    function dbusIntrospect(bus, dest, path, callback) {
        sendRequest("dbus.introspect", {
            "bus": bus,
            "dest": dest,
            "path": path || "/"
        }, callback);
    }

    function dbusListNames(bus, callback) {
        sendRequest("dbus.listNames", {
            "bus": bus
        }, callback);
    }

    function dbusSubscribe(bus, sender, path, iface, member, callback) {
        sendRequest("dbus.subscribe", {
            "bus": bus,
            "sender": sender || "",
            "path": path || "",
            "interface": iface || "",
            "member": member || ""
        }, response => {
            if (!response.error && response.result?.subscriptionId) {
                dbusSubscriptions[response.result.subscriptionId] = true;
            }
            if (callback)
                callback(response);
        });
    }

    function dbusUnsubscribe(subscriptionId, callback) {
        sendRequest("dbus.unsubscribe", {
            "subscriptionId": subscriptionId
        }, response => {
            if (!response.error) {
                delete dbusSubscriptions[subscriptionId];
            }
            if (callback)
                callback(response);
        });
    }

    function sysupdateGetState(callback) {
        sendRequest("sysupdate.getState", null, callback);
    }

    function sysupdateRefresh(force, callback) {
        sendRequest("sysupdate.refresh", {
            "force": force === true
        }, callback);
    }

    function sysupdateUpgrade(opts, callback) {
        const params = opts || {};
        sendRequest("sysupdate.upgrade", params, callback);
    }

    function sysupdateCancel(callback) {
        sendRequest("sysupdate.cancel", null, callback);
    }

    function sysupdateSetInterval(seconds, callback) {
        sendRequest("sysupdate.setInterval", {
            "seconds": seconds
        }, callback);
    }

    function sysupdateAcquire(callback) {
        sendRequest("sysupdate.acquire", null, callback);
    }

    function sysupdateRelease(callback) {
        sendRequest("sysupdate.release", null, callback);
    }
}
