import QtQuick
import Quickshell
import qs.Core

Scope {
    id: host

    property var mountItem: null
    readonly property string currentId: mountItem === null ? "" : mountItem.pluginId

    Component.onCompleted: Plugins.registerPaneHost(host)

    Component {
        id: mountComponent
        Item {
            id: mounted

            required property string pluginId
            required property string payloadJson
            required property string holderHostKey
            property bool sawInstance: false

            anchors.fill: parent

            function focusInitial() {
                const item = slot.instance;
                if (item === null) return;
                const target = item.initialFocus !== undefined && item.initialFocus !== null ? item.initialFocus : item;
                if (typeof target.forceActiveFocus === "function") target.forceActiveFocus(Qt.ShortcutFocusReason);
            }

            PluginSlot {
                id: slot
                kind: "pane"
                pluginId: mounted.pluginId
                hostKey: mounted.holderHostKey
                closeOnUnload: true
                anchors.fill: parent
                focus: true
                onBuilt: instance => {
                    mounted.sawInstance = true;
                    try {
                        instance.open(mounted.payloadJson);
                        mounted.focusInitial();
                    } catch (e) {
                        console.error("panes: " + mounted.pluginId + " open() failed: " + e.message);
                        Qt.callLater(() => host.drop(mounted));
                    }
                }
                onKeyChanged: {
                    if (key === "" && mounted.sawInstance) Qt.callLater(() => host.drop(mounted));
                }
                onBuildFailed: key => Qt.callLater(() => host.drop(mounted))
            }
        }
    }

    function drop(item) {
        if (mountItem !== item) return;
        mountItem = null;
        item.destroy();
    }

    function clear() {
        if (mountItem === null) return;
        const item = mountItem;
        mountItem = null;
        item.destroy();
    }

    function mount(ctx, id, container, payloadJson) {
        if (container === null || container === undefined || typeof container !== "object") return "refused: pane-container=missing";
        clear();
        const item = mountComponent.createObject(container, { pluginId: id, payloadJson: payloadJson, holderHostKey: ctx.hostKey });
        if (item === null) return "refused: pane-container=create-failed";
        mountItem = item;
        return () => {
            if (host.mountItem === item) host.clear();
        };
    }
}
