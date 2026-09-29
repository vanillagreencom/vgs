import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import qs.Ui

// The toast surface: one OverlaySurface on the screen the toast stack
// chose, existing only while a toast shows, in the corner the theme names.
// Each shown toast draws as a Toast component; its close button runs the
// same release an expiry does. The window sizes to the stack, and only the
// shown toasts take pointer input.
Scope {
    id: host

    Component.onCompleted: Plugins.registerHost("toast", host)

    // The close button's global rectangle for the toast at `index`, so a
    // validation row can click it through the compositor.
    function closeGeometry(index) {
        const item = loader.item === null ? null : loader.item.toastAt(index);
        if (item === null) return "absent";
        const button = item.closeButton;
        const at = button.mapToItem(null, 0, 0);
        return JSON.stringify([at.x, at.y, button.width, button.height]);
    }

    function toastWindowGeometry(index) {
        const item = loader.item === null ? null : loader.item.toastAt(index);
        if (item === null) return "absent";
        const at = item.mapToItem(null, 0, 0);
        return JSON.stringify([at.x, at.y, item.width, item.height]);
    }

    Loader {
        id: loader
        active: Toasts.visible.length > 0 && Toasts.screen !== null
        sourceComponent: OverlaySurface {
            id: win

            // The shown toasts, which take the surface's pointer input.
            property var cards: []

            function toastAt(index) { return index < stack.count ? stack.itemAt(index) : null; }

            screen: Toasts.screen
            placement: Theme.toast.corner
            inset: Theme.toast.margin
            inputItems: cards
            implicitWidth: Theme.toast.width
            implicitHeight: Math.max(1, column.implicitHeight)
            WlrLayershell.namespace: "vgs:toast"

            Column {
                id: column
                width: parent.width
                spacing: Theme.toast.gap

                Repeater {
                    id: stack
                    model: Toasts.visible
                    onItemAdded: (index, item) => { win.cards = win.cards.concat([item]); }
                    onItemRemoved: (index, item) => { win.cards = win.cards.filter(card => card !== item); }
                    Toast {
                        required property var modelData
                        width: column.width
                        title: modelData.title
                        message: modelData.message
                        tone: modelData.tone
                        iconName: modelData.icon
                        onDismissed: modelData.release()
                    }
                }
            }
        }
    }
}
