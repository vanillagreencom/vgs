import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Core
import qs.Commons

// The surfaces of one summonable kind: `panel`, `overlay` or `menu`. A
// plugin of that kind is drawn only while summoned. `summon` creates a
// layer surface on the screen it was summoned on, builds the plugin inside
// it and calls its `open(payloadJson)`; `hide` calls `close()` and destroys
// the surface, so nothing of a hidden plugin stays mapped. One surface per
// plugin id; summoning an open one hands it the new payload. A plugin that
// is disabled while open is closed with its surface.
Scope {
    id: host

    required property string kind

    // Ids open now, the Variants model, replaced whole on every change.
    property var openIds: []
    // id -> { payloadJson, anchor, screen }: what each open id was summoned with.
    property var requests: ({})
    // id -> the built instance, set when its slot builds.
    property var instances: ({})

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
    // an IPC summon, or { anchor, screen } for one from a plugin: the rect
    // of the item it came from, relative to its screen, and that screen.
    function summon(id, payloadJson, origin) {
        if (PluginLogic.hasOwn(instances, id)) {
            instances[id].open(payloadJson);
            return "ok";
        }
        const screen = origin && origin.screen ? origin.screen : focusedScreen();
        if (screen === null) return "refused: screen=none";
        const next = Object.assign({}, requests);
        next[id] = { payloadJson: payloadJson, anchor: origin ? origin.anchor : null, screen: screen };
        requests = next;
        openIds = openIds.concat([id]);
        if (!PluginLogic.hasOwn(instances, id)) {
            drop(id);
            return "refused: build-failed=" + id;
        }
        return "ok";
    }

    function hide(id) {
        if (PluginLogic.hasOwn(instances, id)) instances[id].close();
        drop(id);
        return "ok";
    }

    function toggle(id, payloadJson, origin) {
        return PluginLogic.hasOwn(instances, id) ? hide(id) : summon(id, payloadJson, origin);
    }

    function built(id, instance) {
        const next = Object.assign({}, instances);
        next[id] = instance;
        instances = next;
        instance.open(requests[id].payloadJson);
    }

    function drop(id) {
        if (openIds.indexOf(id) === -1) return;
        const nextInstances = Object.assign({}, instances);
        delete nextInstances[id];
        instances = nextInstances;
        openIds = openIds.filter(o => o !== id);
        const nextRequests = Object.assign({}, requests);
        delete nextRequests[id];
        requests = nextRequests;
    }

    Variants {
        model: host.openIds

        PanelWindow {
            id: win

            required property string modelData
            readonly property var request: host.requests[modelData]
            readonly property var place: {
                const settings = Plugins.settingsOf(modelData);
                const size = { width: implicitWidth, height: implicitHeight };
                const area = { width: screen ? screen.width : 0, height: screen ? screen.height : 0 };
                return PluginLogic.surfacePlacement(host.kind, settings, request ? request.anchor : null, size, area, Style.spacing.lg);
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
            WlrLayershell.layer: host.kind === "panel" ? WlrLayer.Top : WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            // Dropped after the current change settles, never from inside the
            // Variants update that created this window.
            readonly property bool live: Plugins.slotKey(modelData) !== ""
            onLiveChanged: if (!live) Qt.callLater(() => host.drop(win.modelData))
            Component.onCompleted: if (place.error !== "") console.error("summon host: " + modelData + " " + place.error)

            PluginSlot {
                id: slot
                kind: host.kind
                pluginId: win.modelData
                hostKey: host.kind
                screen: win.screen
                anchors.fill: parent
                onBuilt: instance => host.built(win.modelData, instance)
                onBuildFailed: key => Qt.callLater(() => host.drop(win.modelData))
            }
        }
    }
}
