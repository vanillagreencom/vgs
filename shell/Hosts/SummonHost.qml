import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Core
import qs.Commons

// The surfaces of one summonable kind: `panel`, `overlay` or `menu`. A
// plugin of that kind is drawn only while summoned. `summon` creates a
// surface on the screen it was summoned on, builds the plugin inside
// it and calls its `open(payloadJson)`; `hide` destroys the surface, and
// the slot calls `close()` first, so nothing of a hidden plugin stays
// mapped. One surface per plugin id; summoning an open one hands it the new
// payload. A plugin disabled while open is closed the same way. An open()
// that throws is logged and refuses the summon; a close() that throws is
// logged and the surface still goes.
Scope {
    id: host

    required property string kind

    // Ids open now, the Variants model, replaced whole on every change.
    property var openIds: []
    // id -> { payloadJson, anchor, screen }: what each open id was summoned with.
    property var requests: ({})
    // id -> the built instance, set when its slot builds.
    property var instances: ({})
    // id -> the error its first open() threw, read by summon.
    property var openErrors: ({})

    Component.onCompleted: Plugins.registerHost(kind, host)

    // The screen a summon without an anchor lands on: the focused monitor,
    // or the first screen when Hyprland names none Quickshell knows.
    function focusedScreen() {
        const monitor = Hyprland.focusedMonitor;
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++)
            if (monitor !== null && screens[i].name === monitor.name) return screens[i];
        return screens.length > 0 ? screens[0] : null;
    }

    // Open `id`, or hand an open one the new payload. `origin` is null for
    // an IPC summon, or { anchor, screen } for one from a plugin. The
    // anchor is the item whose window owns the popup.
    function summon(id, payloadJson, origin) {
        if (PluginLogic.hasOwn(instances, id)) {
            const next = Object.assign({}, requests);
            next[id] = Object.assign({}, requests[id], { payloadJson: payloadJson });
            requests = next;
            const error = callOpen(id, instances[id], payloadJson);
            if (error === "") return "ok";
            drop(id);
            return "refused: open-failed=" + id;
        }
        const screen = origin && origin.screen ? origin.screen : focusedScreen();
        if (screen === null) return "refused: screen=none";
        const next = Object.assign({}, requests);
        next[id] = { payloadJson: payloadJson, anchor: origin ? origin.anchor : null, anchored: !!(origin && origin.anchor), screen: screen };
        requests = next;
        openIds = openIds.concat([id]);
        if (!PluginLogic.hasOwn(instances, id)) {
            drop(id);
            return "refused: build-failed=" + id;
        }
        if (PluginLogic.hasOwn(openErrors, id)) {
            drop(id);
            return "refused: open-failed=" + id;
        }
        return "ok";
    }

    function hide(id) {
        drop(id);
        return "ok";
    }

    // Call one instance's open(); "" when it returned, else the error, logged.
    function callOpen(id, instance, payloadJson) {
        try {
            instance.open(payloadJson);
            return "";
        } catch (e) {
            console.error("summon host: " + id + " open() failed: " + e.message);
            return e.message;
        }
    }

    function toggle(id, payloadJson, origin) {
        return PluginLogic.hasOwn(instances, id) ? hide(id) : summon(id, payloadJson, origin);
    }

    function built(id, instance) {
        const next = Object.assign({}, instances);
        next[id] = instance;
        instances = next;
        const error = callOpen(id, instance, requests[id].payloadJson);
        if (error === "") return;
        const errors = Object.assign({}, openErrors);
        errors[id] = error;
        openErrors = errors;
    }

    function drop(id) {
        if (openIds.indexOf(id) === -1) return;
        const nextInstances = Object.assign({}, instances);
        delete nextInstances[id];
        instances = nextInstances;
        const nextErrors = Object.assign({}, openErrors);
        delete nextErrors[id];
        openErrors = nextErrors;
        openIds = openIds.filter(o => o !== id);
        const nextRequests = Object.assign({}, requests);
        delete nextRequests[id];
        requests = nextRequests;
    }

    Variants {
        model: host.openIds

        Scope {
            id: entry

            required property string modelData
            readonly property var request: host.requests[modelData]
            readonly property bool live: Registry.slotKey(modelData) !== ""
            onLiveChanged: if (!live) Qt.callLater(() => host.drop(entry.modelData))

            Loader {
                active: entry.request !== undefined
                sourceComponent: entry.request && entry.request.anchored ? popup : layer
            }

            Component {
                id: popup
                SummonPopup {
                    pluginId: entry.modelData
                    kind: host.kind
                    request: entry.request
                    onBuilt: instance => host.built(entry.modelData, instance)
                    onDismissed: Qt.callLater(() => host.drop(entry.modelData))
                }
            }

            Component {
                id: layer
                PanelWindow {
                    id: win

                    readonly property var request: entry.request
                    readonly property var place: {
                        const settings = Registry.settingsOf(entry.modelData, host.kind);
                        return PluginLogic.surfacePlacement(host.kind, settings, Style.spacing.lg);
                    }

                    screen: request ? request.screen : null
                    anchors { top: place.anchors.top; bottom: place.anchors.bottom; left: place.anchors.left; right: place.anchors.right }
                    margins { top: place.margins.top; bottom: place.margins.bottom; left: place.margins.left; right: place.margins.right }
                    exclusionMode: place.exclusion === "ignore" ? ExclusionMode.Ignore : ExclusionMode.Normal
                    exclusiveZone: 0
                    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
                    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
                    color: "transparent"
                    WlrLayershell.namespace: "vgs:" + host.kind
                    WlrLayershell.layer: place.layer === "top" ? WlrLayer.Top : WlrLayer.Overlay
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

                    Component.onCompleted: if (place.error !== "") console.error("summon host: " + entry.modelData + " " + place.error)

                    PluginSlot {
                        id: slot
                        kind: host.kind
                        pluginId: entry.modelData
                        hostKey: host.kind
                        screen: win.screen
                        closeOnUnload: true
                        anchors.fill: parent
                        onBuilt: instance => host.built(entry.modelData, instance)
                        onBuildFailed: key => Qt.callLater(() => host.drop(entry.modelData))
                    }
                }
            }
        }
    }
}
