import QtQuick
import QtQml.Models
import Quickshell
import qs.Commons

// The anchor's window owns the popup; the compositor adjusts its position
// at screen edges. Losing that window or a menu grab closes the instance.
PopupWindow {
    id: popup

    required property string pluginId
    required property string kind
    required property var request
    readonly property Item anchorItem: request ? request.anchor : null
    signal built(var instance)
    signal dismissed()

    anchor.item: anchorItem
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
    grabFocus: kind === "menu"
    visible: anchorItem !== null
    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
    color: "transparent"
    onVisibleChanged: if (!visible) dismissed()
    onAnchorItemChanged: if (anchorItem === null) dismissed()

    // PopupAnchor does not track movement. Observe every parent because
    // layout can move the anchor without changing its own x or y. The
    // update is logged once per move: Quickshell sends the compositor the
    // new anchor on the popup's next frame, which a validation row reads
    // back only when the shell draws.
    function followAnchor() {
        console.info("summon popup: anchor updated for " + pluginId);
        anchor.updateAnchor();
    }
    readonly property var anchorChain: {
        const chain = [];
        for (let item = anchorItem; item; item = item.parent) chain.push(item);
        return chain;
    }
    Instantiator {
        model: popup.anchorChain
        delegate: Connections {
            required property var modelData
            target: modelData
            function onXChanged() { popup.followAnchor(); }
            function onYChanged() { popup.followAnchor(); }
            function onWidthChanged() { popup.followAnchor(); }
            function onHeightChanged() { popup.followAnchor(); }
            function onRotationChanged() { popup.followAnchor(); }
            function onScaleChanged() { popup.followAnchor(); }
            function onVisibleChanged() { if (!target.visible) popup.dismissed(); }
        }
    }

    PluginSlot {
        id: slot
        kind: popup.kind
        pluginId: popup.pluginId
        hostKey: popup.kind
        screen: popup.screen
        closeOnUnload: true
        anchors.fill: parent
        onBuilt: instance => popup.built(instance)
        onBuildFailed: key => popup.dismissed()
    }
}
