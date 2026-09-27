import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "../../../Common/LayoutCodes.js" as LayoutCodes

BasePill {
    id: root

    property var widgetData: null
    property bool compactMode: widgetData?.keyboardLayoutNameCompactMode !== undefined ? widgetData.keyboardLayoutNameCompactMode : SettingsData.keyboardLayoutNameCompactMode
    property bool showIcon: widgetData?.keyboardLayoutNameShowIcon !== undefined ? widgetData.keyboardLayoutNameShowIcon : SettingsData.keyboardLayoutNameShowIcon
    readonly property var validVariants: ["US", "UK", "GB", "AZERTY", "QWERTY", "Dvorak", "Colemak", "Mac", "Intl", "International"]
    property string currentLayout: {
        if (CompositorService.isNiri) {
            return NiriService.getCurrentKeyboardLayoutName();
        } else if (CompositorService.isMango) {
            return MangoService.currentKeyboardLayout;
        }
        return "";
    }
    property string hyprlandKeyboard: ""

    content: Component {
        Item {
            implicitWidth: root.isVerticalOrientation ? (root.widgetThickness - root.horizontalPadding * 2) : contentRow.implicitWidth
            implicitHeight: root.isVerticalOrientation ? contentColumn.implicitHeight : (root.widgetThickness - root.horizontalPadding * 2)

            Column {
                id: contentColumn
                visible: root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: 1

                VgsIcon {
                    name: "keyboard"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: Theme.widgetTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.showIcon
                }

                StyledText {
                    text: LayoutCodes.layoutCode(root.currentLayout)
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.widgetTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            Row {
                id: contentRow
                visible: !root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: Theme.spacingS

                VgsIcon {
                    name: "keyboard"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: Theme.widgetTextColor
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.showIcon
                }

                StyledText {
                    text: {
                        if (!root.currentLayout)
                            return "";
                        if (root.compactMode && !CompositorService.isHyprland) {
                            const match = root.currentLayout.match(/^(\S+)(?:.*\(([^)]+)\))?/);
                            if (match) {
                                const lang = match[1].toLowerCase();
                                const code = LayoutCodes.LANG_CODES[lang] || lang.substring(0, 2);
                                if (match[2]) {
                                    const variant = match[2].trim();
                                    const isValid = root.validVariants.some(v => variant.toUpperCase().includes(v.toUpperCase())) || variant.length <= 3;
                                    if (isValid)
                                        return code + "-" + variant;
                                }
                                return code.toUpperCase();
                            }
                            return root.currentLayout.substring(0, 2).toUpperCase();
                        }
                        return root.currentLayout;
                    }
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.widgetTextColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    MouseArea {
        z: 1
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.triggerRipple(this, mouse.x, mouse.y);
        }
        onClicked: {
            if (CompositorService.isNiri) {
                NiriService.cycleKeyboardLayout();
            } else if (CompositorService.isHyprland) {
                Quickshell.execDetached(["hyprctl", "switchxkblayout", root.hyprlandKeyboard, "next"]);
            } else if (CompositorService.isMango) {
                MangoService.cycleKeyboardLayout();
            }
        }
    }

    Connections {
        target: CompositorService.isHyprland ? Hyprland : null
        enabled: CompositorService.isHyprland

        function onRawEvent(event) {
            if (event.name === "activelayout") {
                updateLayout();
            }
        }
    }

    Component.onCompleted: {
        if (CompositorService.isHyprland) {
            updateLayout();
        }
    }

    function updateLayout() {
        if (CompositorService.isHyprland) {
            Proc.runCommand(null, ["hyprctl", "-j", "devices"], (output, exitCode) => {
                if (exitCode !== 0) {
                    root.currentLayout = "Unknown";
                    return;
                }
                try {
                    const data = JSON.parse(output);
                    const mainKeyboard = data.keyboards.find(kb => kb.main === true);
                    root.hyprlandKeyboard = mainKeyboard.name;

                    if (mainKeyboard) {
                        const layout = mainKeyboard.layout;
                        const variant = mainKeyboard.variant;
                        const index = mainKeyboard.active_layout_index;

                        if (root.compactMode && layout && index !== undefined) {
                            const layouts = mainKeyboard.layout.split(",");
                            const variants = mainKeyboard.variant.split(",");
                            const index = mainKeyboard.active_layout_index;

                            if (layouts[index] && variants[index] !== undefined) {
                                if (variants[index] === "") {
                                    root.currentLayout = layouts[index];
                                } else {
                                    root.currentLayout = layouts[index] + "-" + variants[index];
                                }
                            } else {
                                root.currentLayout = layouts[index];
                            }
                        } else if (mainKeyboard && mainKeyboard.active_keymap) {
                            root.currentLayout = mainKeyboard.active_keymap;
                        } else {
                            root.currentLayout = "Unknown";
                        }
                    } else {
                        root.currentLayout = "Unknown";
                    }
                } catch (e) {
                    root.currentLayout = "Unknown";
                }
            });
        }
    }
}
