import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

BasePill {
    id: root

    property bool isAutoHideBar: false

    readonly property bool inhibited: SessionService.idleInhibited
    readonly property string statusText: inhibited ? I18n.tr("Idle inhibitor on • staying awake") : I18n.tr("Idle inhibitor off • system can sleep")

    readonly property real minTooltipY: {
        if (!parentScreen || !isVerticalOrientation) {
            return 0;
        }

        if (isAutoHideBar) {
            return 0;
        }

        if (parentScreen.y > 0) {
            return barThickness + barSpacing;
        }

        return 0;
    }

    function showTooltip() {
        if (!root.parentScreen || popoutTarget?.shouldBeVisible) {
            return;
        }
        tooltipLoader.active = true;
        if (!tooltipLoader.item) {
            return;
        }

        const tooltipText = root.statusText;
        const currentScreen = root.parentScreen || Screen;

        if (root.isVerticalOrientation) {
            const localPos = clickArea.mapToItem(null, clickArea.width / 2, clickArea.height / 2);
            const adjustedY = localPos.y + root.minTooltipY;
            const tooltipX = root.axis?.edge === "left" ? (root.barThickness + root.barSpacing + Theme.spacingXS) : (currentScreen.width - root.barThickness - root.barSpacing - Theme.spacingXS);
            const isLeft = root.axis?.edge === "left";
            tooltipLoader.item.show(tooltipText, tooltipX, adjustedY, currentScreen, isLeft, !isLeft);
        } else {
            const isBottom = root.axis?.edge === "bottom";
            const localPos = clickArea.mapToItem(null, clickArea.width / 2, 0);

            let tooltipY;
            if (isBottom) {
                const tooltipHeight = Theme.fontSizeSmall * 1.5 + Theme.spacingS * 2;
                tooltipY = currentScreen.height - root.barThickness - root.barSpacing - Theme.spacingXS - tooltipHeight;
            } else {
                tooltipY = root.barThickness + root.barSpacing + Theme.spacingXS;
            }

            tooltipLoader.item.show(tooltipText, localPos.x, tooltipY, currentScreen, false, false);
        }
    }

    content: Component {
        Item {
            implicitWidth: icon.width
            implicitHeight: root.widgetThickness - root.horizontalPadding * 2

            VgsIcon {
                id: icon
                anchors.centerIn: parent
                name: root.inhibited ? "coffee" : "bedtime"
                filled: root.inhibited
                size: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                // Glyph and fill already change with state.
                color: Theme.widgetIconColor

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.InOutQuad
                    }
                }
            }
        }
    }

    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: VgsTooltip {}
    }

    MouseArea {
        id: clickArea
        z: 1
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.triggerRipple(this, mouse.x, mouse.y);
        }
        onClicked: {
            SessionService.toggleIdleInhibit();
            // Refresh the tooltip in place so a still-hovering pointer sees the new state.
            if (containsMouse) {
                root.showTooltip();
            }
        }
        onEntered: {
            root.showTooltip();
        }
        onExited: {
            if (tooltipLoader.item) {
                tooltipLoader.item.hide();
            }
            tooltipLoader.active = false;
        }
    }
}
