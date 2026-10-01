import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import "../Core/HyprlandLayer.js" as Layer

// The surfaces of one summonable kind: `panel`, `overlay`, `menu` or
// `window`. A plugin of that kind is drawn only while summoned. `summon`
// creates a surface on the screen it was summoned on, the one
// PluginLogic.summonSurface names: a layer surface, a popup under an
// anchor, or for `window` an application window whatever the anchor. It
// builds the plugin inside it and calls its `open(payloadJson)`; `hide` destroys the surface, and
// the slot calls `close()` first, so nothing of a hidden plugin stays
// mapped. One surface per plugin id; summoning an open one hands it the new
// payload. A plugin disabled while open is closed the same way. An open()
// that throws is logged and refuses the summon; a close() that throws is
// logged and the surface still goes. A window the user closes through
// Hyprland is hidden the same way.
Scope {
    id: host

    required property string kind

    // Ids open now, the Variants model, replaced whole on every change.
    property var openIds: []
    // id -> { payloadJson, anchor, screen }: what each open id was summoned with.
    property var requests: ({})
    // id -> the built instance, set when its slot builds.
    property var instances: ({})
    // id -> function(reason) that focuses that instance's host slot.
    property var focusers: ({})
    // id -> the error open() threw, read by summon.
    property var openErrors: ({})

    Component.onCompleted: Plugins.registerHost(kind, host)

    // Open `id`, or hand an open one the new payload. `origin` is null for
    // an IPC summon, or { anchor, screen } for one from a plugin. The
    // anchor is the item whose window owns the popup.
    function summon(id, payloadJson, origin) {
        if (PluginLogic.hasOwn(instances, id)) {
            const next = Object.assign({}, requests);
            next[id] = Object.assign({}, requests[id], { payloadJson: payloadJson });
            requests = next;
            const error = callOpen(id, instances[id], payloadJson);
            if (error === "") {
                focusOpen(id, next[id]);
                return "ok";
            }
            drop(id);
            return "refused: open-failed=" + id;
        }
        const screen = origin && origin.screen ? origin.screen : Compositor.focusedScreen();
        if (screen === null) return "refused: screen=none";
        const next = Object.assign({}, requests);
        next[id] = {
            payloadJson: payloadJson,
            anchor: origin ? origin.anchor : null,
            anchored: !!(origin && origin.anchor),
            screen: screen,
            returnFocus: origin && origin.returnFocus ? origin.returnFocus : null,
            returnFocusWasVisual: !!(origin && origin.returnFocusWasVisual)
        };
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

    function navigate(direction) {
        if (host.kind !== "overlay") return "ignored";
        if (Layer.overlayCaptureDirections().indexOf(direction) === -1)
            return "refused: direction=" + JSON.stringify(direction);
        if (openIds.length === 0) return "ignored";
        const id = openIds[openIds.length - 1];
        const instance = instances[id];
        if (instance && typeof instance.navigate === "function") {
            instance.navigate(direction);
            return "ok";
        }
        return "ignored";
    }

    function built(id, instance) {
        const next = Object.assign({}, instances);
        next[id] = instance;
        instances = next;
        const error = callOpen(id, instance, requests[id].payloadJson);
        if (error === "") return true;
        const errors = Object.assign({}, openErrors);
        errors[id] = error;
        openErrors = errors;
        Qt.callLater(() => {
            if (host.instances[id] === instance) host.drop(id);
        });
        return false;
    }

    function focusReason(request) {
        return request && request.anchored ? Qt.MouseFocusReason : Qt.ShortcutFocusReason;
    }

    function focusOpen(id, request) {
        if (PluginLogic.hasOwn(focusers, id)) focusers[id](focusReason(request));
    }

    function rememberFocuser(id, focus) {
        const next = Object.assign({}, focusers);
        next[id] = focus;
        focusers = next;
    }

    function drop(id) {
        if (openIds.indexOf(id) === -1) return;
        const nextInstances = Object.assign({}, instances);
        delete nextInstances[id];
        instances = nextInstances;
        const nextFocusers = Object.assign({}, focusers);
        delete nextFocusers[id];
        focusers = nextFocusers;
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
                sourceComponent: {
                    if (!entry.request) return null;
                    const surface = PluginLogic.summonSurface(host.kind, entry.request.anchored);
                    return surface === "window" ? appWindow : surface === "popup" ? popup : layer;
                }
            }

            Component {
                id: appWindow
                AppWindow {
                    pluginId: entry.modelData
                    kind: host.kind
                    request: entry.request
                    onBuilt: instance => {
                        host.rememberFocuser(entry.modelData, reason => focusInitial(reason));
                        if (host.built(entry.modelData, instance)) focusInitial(host.focusReason(entry.request));
                    }
                    onDismissed: Qt.callLater(() => host.drop(entry.modelData))
                }
            }

            Component {
                id: popup
                SummonPopup {
                    pluginId: entry.modelData
                    kind: host.kind
                    request: entry.request
                    onBuilt: instance => {
                        host.rememberFocuser(entry.modelData, reason => focusInitial(reason));
                        if (host.built(entry.modelData, instance)) focusInitial(host.focusReason(entry.request));
                    }
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
                        return PluginLogic.surfacePlacement(host.kind, settings, Theme.space.md);
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
                    WlrLayershell.keyboardFocus: PluginLogic.layerKeyboardFocus(host.kind, entry.request.anchored) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

                    Component.onCompleted: if (place.error !== "") console.error("summon host: " + entry.modelData + " " + place.error)

                    PluginSlot {
                        id: slot
                        kind: host.kind
                        pluginId: entry.modelData
                        hostKey: host.kind
                        screen: win.screen
                        closeOnUnload: true
                        anchors.fill: parent
                        focus: true
                        Keys.onEscapePressed: host.drop(entry.modelData)
                        onBuilt: instance => {
                            host.rememberFocuser(entry.modelData, reason => slot.focusInitial(reason));
                            if (host.built(entry.modelData, instance)) slot.focusInitial(host.focusReason(entry.request));
                        }
                        onBuildFailed: key => Qt.callLater(() => host.drop(entry.modelData))
                    }
                }
            }
        }
    }
}
