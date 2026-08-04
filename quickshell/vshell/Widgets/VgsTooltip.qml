import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Widgets.Tooltip

// The tooltip for surfaces that cannot contain one: bar widgets, the dock, and
// bundled plugin pills all live in layer surfaces only a widget tall, so the
// tooltip has to be its own Overlay surface. Being a separate surface is also
// what keeps it from stealing pointer/hover from the pill it describes.
//
// Positions are screen-absolute, because the caller is the only thing that
// knows where its bar edge is. For content inside a window big enough to hold
// its own tooltip, use VgsInlineTooltip instead — see
// docs/architecture/design-language.md § Tooltips.
PanelWindow {
    id: root

    WlrLayershell.namespace: "vshell:tooltip"

    property string text: ""
    property real targetX: 0
    property real targetY: 0
    property var targetScreen: null
    property bool alignLeft: false
    property bool alignRight: false

    function show(text, x, y, screen, leftAlign, rightAlign) {
        root.text = text;
        targetScreen = screen ?? null;
        targetX = x;
        targetY = y;
        alignLeft = leftAlign ?? false;
        alignRight = rightAlign ?? false;
        visible = true;
    }

    function hide() {
        visible = false;
    }

    screen: targetScreen
    implicitWidth: body.implicitWidth
    implicitHeight: body.implicitHeight
    color: "transparent"
    visible: false
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1

    anchors {
        top: true
        left: true
    }

    margins {
        left: {
            const screenWidth = targetScreen?.width ?? Screen.width;
            if (alignLeft) {
                return Math.round(Math.max(Theme.spacingS, Math.min(screenWidth - implicitWidth - Theme.spacingS, targetX)));
            } else if (alignRight) {
                return Math.round(Math.max(Theme.spacingS, Math.min(screenWidth - implicitWidth - Theme.spacingS, targetX - implicitWidth)));
            } else {
                return Math.round(Math.max(Theme.spacingS, Math.min(screenWidth - implicitWidth - Theme.spacingS, targetX - implicitWidth / 2)));
            }
        }
        top: {
            const screenHeight = targetScreen?.height ?? Screen.height;
            if (alignLeft || alignRight) {
                return Math.round(Math.max(Theme.spacingS, Math.min(screenHeight - implicitHeight - Theme.spacingS, targetY - implicitHeight / 2)));
            } else {
                return Math.round(Math.max(Theme.spacingS, Math.min(screenHeight - implicitHeight - Theme.spacingS, targetY)));
            }
        }
    }

    WindowBlur {
        targetWindow: root
        blurX: 0
        blurY: 0
        blurWidth: root.visible ? root.width : 0
        blurHeight: root.visible ? root.height : 0
        blurRadius: Theme.controlRadius
    }

    TooltipBody {
        id: body

        anchors.fill: parent
        text: root.text
        maxWidth: 300
        minWidth: 120
    }
}
