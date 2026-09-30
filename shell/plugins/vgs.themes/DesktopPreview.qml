import QtQuick
import qs.Commons
import qs.Ui

Item {
    id: root

    property var tokens: ({})
    property var terminal: null
    property url wallpaper: ""
    property size decodeSize: Qt.size(width, height)
    property string title: "Theme"
    property string commandLine: "vgsh theme apply"
    property var terminalLines: []
    property var fetchLines: []
    property var codeLines: []
    property string notificationTitle: ""
    property string notificationBody: ""

    readonly property color backgroundColor: tokenColor("palette.background", Theme.color.background)
    readonly property color foregroundColor: tokenColor("palette.foreground", Theme.color.text)
    readonly property color accentColor: tokenColor("palette.accent", Theme.color.accent)
    readonly property color surfaceColor: tokenColor("color.surfaceRaised", backgroundColor)
    readonly property color borderColor: tokenColor("color.border", foregroundColor)
    readonly property color activeBorderColor: tokenColor("color.accent", accentColor)
    readonly property color inactiveBorderColor: tokenColor("color.border", borderColor)
    readonly property color mutedColor: tokenColor("color.textMuted", foregroundColor)
    readonly property color shadowColor: tokenColor("hyprland.shadow.color", Theme.hyprland.shadow.color)
    readonly property real borderSize: tokenNumber("hyprland.border.size", Theme.hyprland.border.size)
    readonly property real windowRadius: tokenNumber("hyprland.window.radius", Theme.hyprland.window.radius)
    readonly property real scale: Math.max(width / Theme.desktopPreview.referenceWidth, height / Theme.desktopPreview.referenceHeight)
    readonly property real safeInset: Theme.desktopPreview.gap + Theme.angledCard.skew / Math.max(scale, 0.1)
    readonly property real safeLeft: safeInset + Math.max(0, -desktop.x / Math.max(scale, 0.1))
    readonly property real safeRight: safeInset + Math.max(0, (desktop.x + desktop.width * scale - root.width) / Math.max(scale, 0.1))
    readonly property rect mockBounds: Qt.rect(desktop.x, desktop.y, desktop.width * scale, desktop.height * scale)
    readonly property string accentHex: accentColor.toString()

    function token(path) {
        let node = root.tokens;
        const parts = path.split(".");
        for (let i = 0; i < parts.length; i++) {
            if (node === null || node === undefined) return undefined;
            node = node[parts[i]];
        }
        return node;
    }

    function tokenColor(path, fallback) {
        const value = token(path);
        return typeof value === "string" ? Theme.toColor(value) : fallback;
    }

    function tokenNumber(path, fallback) {
        const value = token(path);
        return typeof value === "number" ? value : fallback;
    }

    function terminalColor(index) {
        const key = "color" + index;
        if (root.terminal !== null && typeof root.terminal === "object" && typeof root.terminal[key] === "string")
            return Theme.toColor(root.terminal[key]);
        if (index === 0) return backgroundColor;
        if (index === 7) return foregroundColor;
        if (index === 1) return tokenColor("palette.danger", accentColor);
        if (index === 2) return tokenColor("palette.success", accentColor);
        if (index === 3) return tokenColor("palette.warning", accentColor);
        if (index === 4) return tokenColor("palette.info", accentColor);
        return mutedColor;
    }

    Rectangle {
        anchors.fill: parent
        color: root.backgroundColor
    }

    Image {
        anchors.fill: parent
        source: root.wallpaper
        sourceSize: root.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: source.toString() !== ""
    }

    Item {
        id: desktop
        x: (root.width - width * scale) / 2
        y: (root.height - height * scale) / 2
        width: Theme.desktopPreview.referenceWidth
        height: Theme.desktopPreview.referenceHeight
        scale: root.scale
        transformOrigin: Item.TopLeft

        Rectangle {
            id: bar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Theme.desktopPreview.barHeight
            color: root.surfaceColor
            opacity: Theme.desktopPreview.barOpacity

            Row {
                anchors.left: parent.left
                anchors.leftMargin: root.safeLeft
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.sm

                Repeater {
                    model: 5
                    Rectangle {
                        required property int index
                        width: Theme.space.xxl
                        height: Theme.space.md
                        radius: Theme.radius.full
                        color: index === 1 ? root.accentColor : root.borderColor
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                role: "bar"
                text: "Tue 16:46"
                color: root.foregroundColor
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: root.safeRight
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.md

                Repeater {
                    model: ["wifi", "cpu", "bat"]
                    Label {
                        required property string modelData
                        role: "bar"
                        color: root.mutedColor
                        text: modelData
                    }
                }
            }
        }

        Rectangle {
            x: terminal.x + Theme.desktopPreview.shadowOffset
            y: terminal.y + Theme.desktopPreview.shadowOffset
            width: terminal.width
            height: terminal.height
            radius: terminal.radius
            color: root.shadowColor
        }

        Rectangle {
            id: terminal
            x: root.safeLeft
            y: bar.height + Theme.desktopPreview.gap
            width: (parent.width - root.safeLeft - root.safeRight - Theme.desktopPreview.gap) * Theme.desktopPreview.terminalWidthShare
            height: parent.height - y - root.safeInset
            radius: root.windowRadius
            color: root.surfaceColor
            border.color: root.activeBorderColor
            border.width: Math.max(Theme.border.thin, root.borderSize)

            Column {
                anchors.fill: parent
                anchors.margins: Theme.space.lg
                spacing: Theme.space.sm

                Repeater {
                    model: root.terminalLines
                    Label {
                        required property var modelData
                        role: "code"
                        color: root.terminalColor(modelData.color)
                        text: modelData.text
                    }
                }
                Grid {
                    width: parent.width
                    columns: 8
                    spacing: Theme.space.xs
                    Repeater {
                        model: 16
                        Rectangle {
                            required property int index
                            width: (terminal.width - 2 * Theme.space.lg - 7 * Theme.space.xs) / 8
                            height: Theme.space.lg
                            color: root.terminalColor(index)
                        }
                    }
                }
                Repeater {
                    model: root.fetchLines
                    Label {
                        required property var modelData
                        role: "code"
                        color: root.terminalColor(modelData.color)
                        text: modelData.text
                    }
                }
            }
        }

        Rectangle {
            id: editor
            x: terminal.x + terminal.width + Theme.desktopPreview.gap
            y: terminal.y
            width: parent.width - editor.x - root.safeRight
            height: terminal.height * Theme.desktopPreview.panelHeightShare
            radius: root.windowRadius
            color: root.surfaceColor
            border.color: root.inactiveBorderColor
            border.width: Math.max(Theme.border.thin, root.borderSize)

            Column {
                anchors.fill: parent
                anchors.margins: Theme.space.lg
                spacing: Theme.space.xs

                Repeater {
                    model: root.codeLines
                    Label {
                        required property var modelData
                        role: "code"
                        color: root.terminalColor(modelData.color)
                        text: modelData.text
                    }
                }
            }
        }

        Rectangle {
            x: editor.x
            y: editor.y + editor.height + Theme.desktopPreview.gap
            width: editor.width
            height: parent.height - y - root.safeRight
            radius: root.windowRadius
            color: root.surfaceColor
            border.color: root.inactiveBorderColor
            border.width: Theme.border.thin

            Column {
                anchors.fill: parent
                anchors.margins: Theme.space.lg
                spacing: Theme.space.sm

                Label { role: "label"; color: root.mutedColor; text: root.title }
                Rectangle { width: parent.width; height: Theme.space.xxl; radius: Theme.radius.sm; color: root.accentColor }
                Label { role: "body"; color: root.foregroundColor; width: parent.width; elide: Text.ElideRight; text: root.notificationTitle }
                Label { role: "hint"; color: root.mutedColor; width: parent.width; elide: Text.ElideRight; text: root.notificationBody }
            }
        }
    }
}
