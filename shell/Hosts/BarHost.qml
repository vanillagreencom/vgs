import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// One bar surface per screen. The core owns the window; the active bar
// plugin draws inside `slot`. The plugin instance is rebuilt when the active
// bar id, the plugin generation or the screen changes, and destroyed first
// so no two bars ever share the slot.
PanelWindow {
    id: host

    required property var modelData
    screen: modelData

    anchors { top: true; left: true; right: true }
    implicitHeight: Style.bar.sizeHorizontal
    exclusiveZone: implicitHeight
    color: Color.bar.background
    WlrLayershell.namespace: "vgs:bar"
    WlrLayershell.layer: WlrLayer.Top

    property var instance: null
    property string loadedKey: ""

    readonly property string barId: Plugins.activeBarId
    readonly property bool barEnabled: Plugins.isEnabled(barId)
    readonly property string key: Plugins.scanned && barEnabled ? barId + "@" + Plugins.generation : ""

    // The bar reads a snapshot of its configuration; hand it a new one when
    // the effective configuration changes, so a layout edit rebuilds widgets.
    Connections {
        target: Config
        function onEffectiveChanged() {
            if (host.instance !== null) host.instance.barConfig = Config.effective.bar || {};
        }
    }

    Item {
        id: slot
        anchors.fill: parent
    }

    onKeyChanged: reload()
    Component.onCompleted: reload()

    function unload() {
        if (instance !== null) { instance.destroy(); instance = null; }
        loadedKey = "";
    }

    function reload() {
        if (key === loadedKey) return;
        unload();
        if (key === "") return;
        const manifest = Plugins.manifests[barId];
        if (manifest === undefined) {
            console.error("bar host: active bar " + JSON.stringify(barId) + " is not a discovered plugin");
            return;
        }
        const url = Plugins.entryUrl(barId, "bar");
        const component = Qt.createComponent(url);
        if (component.status !== Component.Ready) {
            console.error("bar host: " + barId + " failed to load: " + component.errorString());
            return;
        }
        instance = component.createObject(slot);
        if (instance === null) {
            console.error("bar host: " + barId + " created no object");
            return;
        }
        // Assigned after creation, not passed as initial properties: initial
        // properties cross a QVariant conversion that drops functions from
        // the facade and turns nested lists into non-Array sequences.
        instance.anchors.fill = slot;
        instance.screen = host.screen;
        instance.shell = Plugins.facadeFor(manifest);
        instance.barConfig = Config.effective.bar || {};
        loadedKey = key;
    }
}
