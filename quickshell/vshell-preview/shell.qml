// Minimal VGS preview shell: renders wallpaper, a bar, and an open
// control-center flyout styled from the theme.json referenced by
// $VGS_PREVIEW_THEME. Used only by `vshell theme preview` inside the nested
// screenshot compositor; it must stay self-contained (no qs.* imports, no
// SettingsData/SessionData dependencies).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property var theme: ({})
    readonly property var colors: theme.colors || {}
    readonly property bool lightMode: (theme.mode || "dark") === "light"
    readonly property string wallpaper: Quickshell.env("VGS_PREVIEW_WALLPAPER") || ""

    function c(role, fallback) {
        const value = colors[role];
        return value && value !== "" ? value : fallback;
    }

    readonly property color surface: c("surfaceContainer", lightMode ? "#e6e9ef" : "#20222c")
    readonly property color surfaceHigh: c("surfaceContainerHigh", lightMode ? "#dce0e8" : "#282a36")
    readonly property color surfaceHighest: c("surfaceContainerHighest", lightMode ? "#ccd0da" : "#2c2f3c")
    readonly property color surfaceText: c("foreground", lightMode ? "#22232b" : "#c8ccd4")
    readonly property color mutedText: c("muted", lightMode ? "#6a6d7b" : "#8a8ea0")
    readonly property color accent: c("accent", "#7aa2f7")
    readonly property color onAccent: c("onPrimary", lightMode ? "#ffffff" : "#0c0e14")
    readonly property color bgColor: c("background", lightMode ? "#eff1f5" : "#101018")

    FontLoader {
        id: iconFont
        source: Qt.resolvedUrl("assets/MaterialSymbolsRounded.ttf")
    }

    FontLoader {
        id: uiFont
        source: Qt.resolvedUrl("assets/InterVariable.ttf")
    }

    component MatIcon: Text {
        property real size: 20
        width: size
        height: size
        clip: true
        font.family: iconFont.name
        font.pixelSize: size
        font.weight: 400
        color: root.surfaceText
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }

    component UiText: Text {
        font.family: uiFont.name
        color: root.surfaceText
        font.pixelSize: 14
    }

    FileView {
        path: Quickshell.env("VGS_PREVIEW_THEME")
        blockLoading: true
        onLoaded: {
            try {
                root.theme = JSON.parse(text());
            } catch (e) {
                console.warn("preview theme parse failed:", e);
            }
        }
    }

    PanelWindow {
        id: background

        WlrLayershell.layer: WlrLayer.Background
        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        exclusiveZone: -1
        color: root.bgColor

        Image {
            anchors.fill: parent
            visible: root.wallpaper !== ""
            source: root.wallpaper ? "file://" + root.wallpaper : ""
            fillMode: Image.PreserveAspectCrop
        }
    }

    PanelWindow {
        id: bar

        anchors.top: true
        anchors.left: true
        anchors.right: true
        margins.top: 8
        margins.left: 12
        margins.right: 12
        implicitHeight: 42
        exclusiveZone: -1
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: root.surface

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                MatIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "apps"
                    color: root.surfaceText
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Repeater {
                        model: 5

                        Rectangle {
                            required property int index
                            width: index === 1 ? 28 : 12
                            height: 12
                            radius: 6
                            anchors.verticalCenter: parent.verticalCenter
                            color: index === 1 ? root.accent : root.surfaceHighest
                        }
                    }
                }

                UiText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.theme.name || "vgs-theme"
                    color: root.mutedText
                    font.pixelSize: 13
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14

                MatIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "wifi"
                    size: 18
                }

                MatIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "bluetooth"
                    size: 18
                }

                MatIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "volume_up"
                    size: 18
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 18
                    radius: 9
                    color: root.surfaceHighest

                    Rectangle {
                        anchors.left: parent.left
                        anchors.leftMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.72
                        height: 14
                        radius: 7
                        color: root.accent
                    }
                }

                UiText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "09:41"
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
            }
        }
    }

    PanelWindow {
        id: flyout

        anchors.top: true
        anchors.right: true
        margins.top: 58
        margins.right: 12
        implicitWidth: 400
        implicitHeight: 486
        exclusiveZone: -1
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: 18
            color: root.surface

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                Rectangle {
                    width: parent.width
                    height: 66
                    radius: 14
                    color: root.surfaceHigh

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 12

                        Rectangle {
                            width: 42
                            height: 42
                            radius: 21
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.accent

                            UiText {
                                anchors.centerIn: parent
                                text: "M"
                                color: root.onAccent
                                font.pixelSize: 17
                                font.weight: Font.DemiBold
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            UiText {
                                text: "method"
                                font.pixelSize: 15
                                font.weight: Font.Medium
                            }

                            UiText {
                                text: "up 1 day, 2 hours"
                                color: root.mutedText
                                font.pixelSize: 12
                            }
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 14

                        Repeater {
                            model: ["photo_library", "lock", "power_settings_new", "settings", "edit"]

                            MatIcon {
                                required property string modelData
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                size: 18
                                color: root.surfaceText
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 12

                    Repeater {
                        model: [
                            { icon: "volume_up", value: 0.39 },
                            { icon: "brightness_6", value: 0.08 }
                        ]

                        Row {
                            required property var modelData
                            width: (parent.width - 12) / 2
                            spacing: 8

                            MatIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                text: parent.modelData.icon
                                size: 20
                                color: root.accent
                            }

                            Item {
                                width: parent.width - 28
                                height: 24
                                anchors.verticalCenter: parent.verticalCenter

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 8
                                    radius: 4
                                    color: root.surfaceHighest
                                }

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(10, parent.width * parent.parent.modelData.value)
                                    height: 8
                                    radius: 4
                                    color: root.accent
                                }

                                Rectangle {
                                    x: Math.max(10, parent.width * parent.parent.modelData.value) - 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 3
                                    height: 16
                                    radius: 1.5
                                    color: root.accent
                                }
                            }
                        }
                    }
                }

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 12

                    Repeater {
                        model: [
                            { icon: "settings_ethernet", label: "Ethernet", sub: "Connected" },
                            { icon: "bluetooth", label: "Enabled", sub: "HT-AX7" },
                            { icon: "volume_up", label: "HT-AX7", sub: "39%" },
                            { icon: "mic", label: "Shure MV7 Mono", sub: "98%" }
                        ]

                        Rectangle {
                            required property var modelData
                            width: (parent.width - 12) / 2
                            height: 64
                            radius: 14
                            color: root.surfaceHigh

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10

                                Rectangle {
                                    width: 48
                                    height: 48
                                    radius: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: root.accent

                                    MatIcon {
                                        anchors.centerIn: parent
                                        text: parent.parent.parent.modelData.icon
                                        size: 22
                                        color: root.onAccent
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    UiText {
                                        text: parent.parent.parent.modelData.label
                                        font.pixelSize: 13
                                        font.weight: Font.Medium
                                        width: 108
                                        elide: Text.ElideRight
                                    }

                                    UiText {
                                        text: parent.parent.parent.modelData.sub
                                        color: root.mutedText
                                        font.pixelSize: 12
                                        width: 108
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 12

                    Repeater {
                        model: [
                            { icon: "nightlight", label: "Night Mode", active: false },
                            { icon: "contrast", label: "Dark Mode", active: !root.lightMode }
                        ]

                        Rectangle {
                            required property var modelData
                            width: (parent.width - 12) / 2
                            height: 58
                            radius: 14
                            color: modelData.active ? root.accent : root.surfaceHigh

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10

                                MatIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: parent.parent.modelData.icon
                                    size: 20
                                    color: parent.parent.modelData.active ? root.onAccent : root.accent
                                }

                                UiText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: parent.parent.modelData.label
                                    color: parent.parent.modelData.active ? root.onAccent : root.surfaceText
                                    font.pixelSize: 14
                                    font.weight: Font.Medium
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
