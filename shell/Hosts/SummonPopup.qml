import QtQuick
import QtQml.Models
import Quickshell
import qs.Commons

// The anchor's window owns the popup; the compositor adjusts its position
// at screen edges. Every anchored surface takes the focus grab: it is what
// gives the popup keyboard focus under a bar whose layer takes none, and
// what closes it on a click outside. Losing the anchor closes it too.
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
    grabFocus: true
    visible: anchorItem !== null
    // The room the output leaves, `size.window.gutter` in from each edge: a
    // plugin wider or taller than that is laid out at the room's size, since
    // the plugin fills the popup, and the compositor's slide keeps the
    // popup inside the output.
    readonly property var output: request && request.screen ? request.screen : null
    readonly property real roomWidth: output ? output.width - 2 * Theme.size.window.gutter : Infinity
    readonly property real roomHeight: output ? output.height - 2 * Theme.size.window.gutter : Infinity
    implicitWidth: slot.instance ? Math.max(1, Math.min(slot.instance.implicitWidth, roomWidth)) : 1
    implicitHeight: slot.instance ? Math.max(1, Math.min(slot.instance.implicitHeight, roomHeight)) : 1
    color: "transparent"
    onVisibleChanged: if (!visible) dismissed()
    onAnchorItemChanged: if (anchorItem === null) dismissed()

    // The anchor is re-read on every move of the item or an ancestor, since
    // a layout can move the item without changing its own x or y. The
    // compositor learns the new anchor on the popup's next frame; the log
    // line is the validation rows' readback until then.
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
