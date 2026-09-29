import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import qs.Ui

// The toast surface: one layer window on the screen the toast stack chose,
// existing only while a toast shows, in the corner the theme names. Each
// shown toast draws as a Toast component; its close button runs the same
// release an expiry does. The window sizes to the stack.
Scope {
    id: host

    readonly property var corner: Theme.toast.corner.split("-")
    readonly property bool onTop: corner[0] === "top"
    readonly property bool onLeft: corner[1] === "left"

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
        sourceComponent: PanelWindow {
            id: win

            function toastAt(index) { return index < stack.count ? stack.itemAt(index) : null; }

            screen: Toasts.screen
            anchors { top: host.onTop; bottom: !host.onTop; left: host.onLeft; right: !host.onLeft }
            margins { top: Theme.toast.margin; bottom: Theme.toast.margin; left: Theme.toast.margin; right: Theme.toast.margin }
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            implicitWidth: Theme.toast.width
            implicitHeight: Math.max(1, column.implicitHeight)
            color: "transparent"
            mask: inputRegion
            WlrLayershell.namespace: "vgs:toast"
            WlrLayershell.layer: WlrLayer.Overlay

            Region {
                id: inputRegion
                regions: inputRegions.items
            }

            Instantiator {
                id: inputRegions
                property var items: []
                model: Toasts.visible
                onObjectAdded: (index, object) => {
                    const next = items.slice();
                    next.splice(index, 0, object);
                    items = next;
                }
                onObjectRemoved: (index, object) => {
                    const next = items.filter(item => item !== object);
                    items = next;
                }
                delegate: Region {
                    required property int index
                    item: win.toastAt(index)
                }
            }

            Column {
                id: column
                width: parent.width
                spacing: Theme.toast.gap

                Repeater {
                    id: stack
                    model: Toasts.visible
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
