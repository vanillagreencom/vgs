pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

Singleton {
    id: root
    readonly property var log: Log.scoped("TailscaleService")

    property int refCount: 0

    onRefCountChanged: {
        if (refCount > 0) {
            ensureSubscription();
        } else if (refCount === 0 && VGSBackendService.activeSubscriptions.includes("tailscale")) {
            VGSBackendService.removeSubscription("tailscale");
        }
    }

    function ensureSubscription() {
        if (refCount <= 0)
            return;
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.activeSubscriptions.includes("tailscale"))
            return;
        if (VGSBackendService.activeSubscriptions.includes("all"))
            return;
        VGSBackendService.addSubscription("tailscale");
        if (available) {
            getStatus();
        }
    }

    property bool connected: false
    property string version: ""
    property string backendState: ""
    property string magicDnsSuffix: ""
    property string tailnetName: ""
    property var selfNode: null
    property var peers: []
    property bool exitNodeAllowLanAccess: false
    property bool acceptRoutes: false
    property string authUrl: ""
    property var healthWarnings: []

    property bool available: false

    // True once the backend has answered at least once. It is NOT a latch that
    // stops further reads: before VGS-63 the single fetch it guarded was the
    // only status the shell ever took, so a shell that started while tailscaled
    // was still warming up displayed "Off" for the rest of the process's life.
    property bool stateInitialized: false

    // The backend pushes on every tailscaled transition when it is watching the
    // ipn bus. Absent on an older backend, which only answers on demand and
    // re-broadcasts after its own write actions — so the shell has to ask.
    readonly property bool backendWatches: VGSBackendService.capabilities.includes("tailscale.watch")

    // "NoState" and "Starting" are tailscaled still coming up, and an empty
    // string is "nobody has told us anything". None of the three is a settled
    // answer, so none of them may be presented as "off" or kept indefinitely.
    readonly property bool backendStateKnown: backendState !== "" && backendState !== "NoState" && backendState !== "Starting"
    readonly property bool starting: stateInitialized && !backendStateKnown

    // Re-fetch cadence. This is a backstop, not a second owner of the state:
    // the backend remains the only thing that reads tailscaled and the only
    // thing that decides what the state is, and the poll is the same
    // tailscale.getStatus request the shell already makes — it cannot produce
    // an answer that disagrees with the owner. What it covers is the shell
    // having no other way to notice that a push never came.
    readonly property int pollIntervalMs: {
        if (!backendStateKnown)
            return 10000;      // warming up: the transition is imminent
        if (backendWatches)
            return 300000;     // pushes are expected; this only catches a dead watcher
        return 45000;          // no watcher at all: the shell is the only thing asking
    }

    Timer {
        running: root.available && root.refCount > 0
        interval: root.pollIntervalMs
        repeat: true
        onTriggered: root.refreshStatus()
    }

    readonly property var allPeersList: {
        const result = [];
        if (selfNode)
            result.push(selfNode);
        if (peers)
            result.push(...peers);
        return result;
    }

    readonly property var onlinePeers: allPeersList.filter(p => p.online)

    // Peers that may be used as an exit node (offered && approved). Self is
    // excluded: a node can never route through itself, and tailscaled rejects it.
    readonly property var exitNodeOptions: allPeersList.filter(p => p && p.exitNodeOption && p !== selfNode)

    // The currently selected exit node, or null if none is in use.
    readonly property var currentExitNode: {
        for (const p of allPeersList) {
            if (p && p.exitNode)
                return p;
        }
        return null;
    }

    readonly property var myPeers: {
        if (!selfNode)
            return allPeersList;
        return allPeersList.filter(p => isMine(p));
    }

    readonly property var myOnlinePeers: {
        if (!selfNode)
            return onlinePeers;
        return allPeersList.filter(p => p.online && isMine(p));
    }

    readonly property int onlinePeerCount: onlinePeers.length

    readonly property string socketPath: Quickshell.env("VGS_SOCKET")

    Component.onCompleted: {
        if (socketPath && socketPath.length > 0) {
            checkVGSCapabilities();
        }
    }

    Connections {
        target: VGSBackendService

        function onConnectionStateChanged() {
            if (VGSBackendService.isConnected) {
                checkVGSCapabilities();
                ensureSubscription();
                // A backend restart means anything held from before the drop is
                // a guess about a daemon nobody was watching.
                refreshStatus();
            }
        }
    }

    Connections {
        target: VGSBackendService
        enabled: VGSBackendService.isConnected

        function onTailscaleStateUpdate(data) {
            root.log.debug("Subscription update received");
            updateState(data);
        }

        function onCapabilitiesReceived() {
            checkVGSCapabilities();
        }
    }

    function checkVGSCapabilities() {
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.capabilities.length === 0)
            return;
        const wasAvailable = available;
        available = VGSBackendService.capabilities.includes("tailscale");

        if (!available)
            return;
        if (!wasAvailable) {
            getStatus();
            ensureSubscription();
        }
    }

    function getStatus() {
        if (!available)
            return;
        VGSBackendService.sendRequest("tailscale.getStatus", null, response => {
            if (response.result) {
                updateState(response.result);
            }
        });
    }

    // Re-read the current status. Call this whenever a Tailscale surface comes
    // into view: it is the moment the user is looking, and it costs one local
    // request.
    function refreshStatus() {
        getStatus();
    }

    function updateState(data) {
        if (!data)
            return;
        stateInitialized = true;
        connected = data.connected || false;
        version = data.version || "";
        backendState = data.backendState || "";
        magicDnsSuffix = data.magicDnsSuffix || "";
        tailnetName = data.tailnetName || "";
        selfNode = data.self || null;
        peers = data.peers || [];
        exitNodeAllowLanAccess = data.exitNodeAllowLanAccess || false;
        acceptRoutes = data.acceptRoutes || false;
        authUrl = data.authUrl || "";
        healthWarnings = data.health || [];
    }

    function refresh(callback) {
        if (!available)
            return;
        VGSBackendService.sendRequest("tailscale.refresh", null, response => {
            if (callback)
                callback(response);
        });
    }

    // sendAction issues a state-changing request. The backend refreshes and
    // broadcasts on success, so subscribers update without an extra getStatus.
    function sendAction(method, params, callback) {
        if (!available)
            return;
        VGSBackendService.sendRequest(method, params, response => {
            if (response.result)
                updateState(response.result);
            if (response.error) {
                root.log.warn(method + " failed: " + response.error);
                ToastService.showError(I18n.tr("Tailscale action failed", "Toast shown when a Tailscale write action is rejected"), response.error);
            }
            if (callback)
                callback(response);
        });
    }

    function connectTailscale(callback) {
        sendAction("tailscale.connect", null, callback);
    }

    function disconnectTailscale(callback) {
        sendAction("tailscale.disconnect", null, callback);
    }

    function setExitNode(id, callback) {
        sendAction("tailscale.setExitNode", {
            "id": id || ""
        }, callback);
    }

    function clearExitNode(callback) {
        setExitNode("", callback);
    }

    function setAllowLanAccess(enabled, callback) {
        sendAction("tailscale.setAllowLanAccess", {
            "enabled": enabled
        }, callback);
    }

    function setAcceptRoutes(enabled, callback) {
        sendAction("tailscale.setAcceptRoutes", {
            "enabled": enabled
        }, callback);
    }

    function exitNodeTarget(peer) {
        if (!peer)
            return "";
        return peer.tailscaleIp || peer.dnsName || peer.hostname || peer.id || "";
    }

    function isMine(peer) {
        const myOwner = selfNode ? (selfNode.owner || "") : "";
        if (peer.owner === myOwner && myOwner !== "")
            return true;
        if (peer.tags && peer.tags.length > 0)
            return true;
        return false;
    }

    function searchPeers(query, list) {
        const base = list || allPeersList;
        if (!query || query.length === 0)
            return base;
        const q = query.toLowerCase();
        return base.filter(p => {
            if (p.hostname && p.hostname.toLowerCase().includes(q))
                return true;
            if (p.dnsName && p.dnsName.toLowerCase().includes(q))
                return true;
            if (p.tailscaleIp && p.tailscaleIp.includes(q))
                return true;
            if (p.os && p.os.toLowerCase().includes(q))
                return true;
            return false;
        });
    }
}
