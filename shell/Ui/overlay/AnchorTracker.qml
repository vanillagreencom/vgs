import QtQuick
import QtQml.Models

// Keeps a popup window with the item it opened from. The compositor places
// the popup once from its anchor rect and moves it again only when the
// anchor is updated, and a hidden anchor leaves it open. This watches the
// anchor and every ancestor for a move, a resize and a hide: a move
// updates the anchor, and a hide closes the popup. It is internal to the
// module; every overlay holds one.
QtObject {
    id: tracker

    required property var popup
    required property Item anchor

    // The anchor and every ancestor up to the window's content item.
    readonly property var chain: {
        const out = [];
        for (let item = anchor; item; item = item.parent) out.push(item);
        return out;
    }

    function follow() {
        if (popup.visible) popup.anchor.updateAnchor();
    }

    readonly property Instantiator watchers: Instantiator {
        model: tracker.chain
        delegate: Connections {
            required property var modelData
            target: modelData
            function onXChanged() { tracker.follow(); }
            function onYChanged() { tracker.follow(); }
            function onWidthChanged() { tracker.follow(); }
            function onHeightChanged() { tracker.follow(); }
            function onVisibleChanged() { if (!target.visible) tracker.popup.visible = false; }
        }
    }
}
