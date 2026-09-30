import QtQuick
import qs.Commons
import qs.Ui
import "Files.js" as Files

// One theme's card on the browser's rail: a package preview image wins
// when one ships, else the selected card draws a live desktop preview from
// the package's tokens over its wallpaper. Side cards stay cheap image or
// palette cards. A Spinner turns over the card while the browser installs
// or applies its theme.
Item {
    id: root

    // The card BrowserLogic.cards built for this theme, with the view's
    // `generation`, the stamp its image loads under.
    required property var modelData
    required property size decodeSize
    // Whether this is the centre card. The carousel sets it only for
    // delegates that declare it.
    property bool current: false
    // Whether the browser is installing, applying or downloading for this
    // theme.
    property bool busy: false

    readonly property var colors: modelData.palette
    readonly property bool packagePreview: typeof modelData.previewImage === "string" && modelData.previewImage !== ""
    readonly property bool livePreview: root.current && !packagePreview && modelData.state === "ok"
    readonly property string cheapImage: packagePreview ? modelData.previewImage : typeof modelData.sharpenedImage === "string" && modelData.sharpenedImage !== "" ? modelData.sharpenedImage : modelData.image
    readonly property bool imageCard: !livePreview && typeof cheapImage === "string" && cheapImage !== ""

    anchors.fill: parent

    DesktopPreview {
        id: preview
        anchors.fill: parent
        visible: root.livePreview
        tokens: root.modelData.tokens
        terminal: root.modelData.terminal
        title: root.modelData.label
        commandLine: "vgsh theme apply " + root.modelData.name
        terminalLines: [
            { text: "➜  " + root.modelData.name + " theme", color: 2 },
            { text: "drwxr-xr-x  shell  plugins  themes", color: 7 },
            { text: "cat theme.json terminal.json", color: 4 }
        ]
        fetchLines: [
            { text: "OS       VGS", color: 6 },
            { text: "WM       Hyprland", color: 5 },
            { text: "Shell    Quickshell", color: 3 },
            { text: "Theme    " + root.modelData.label, color: 2 },
            { text: "Terminal ANSI 16", color: 4 },
            { text: "Font     Mono", color: 7 }
        ]
        codeLines: [
            { text: "const theme = tokens.palette;", color: 5 },
            { text: "window.border = theme.accent;", color: 4 },
            { text: "bar.workspaces.active = accent;", color: 3 },
            { text: "notify(\"Theme applied\");", color: 2 }
        ]
        notificationTitle: "Theme applied"
        notificationBody: root.modelData.label
        wallpaper: root.cheapImage === "" ? "" : Files.stampedUrl(root.cheapImage, root.modelData.generation)
        decodeSize: root.decodeSize
    }

    Rectangle {
        anchors.fill: parent
        visible: !root.livePreview && (image.status === Image.Null || image.status === Image.Error)
        color: root.colors === null ? Theme.color.surface : Theme.toColor(root.colors.background)

        Label {
            role: "h2"
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.space.xxl
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.modelData.label
            color: root.colors === null ? Theme.color.textMuted : Theme.toColor(root.colors.foreground)
        }

    }

    Image {
        id: image
        anchors.fill: parent
        visible: !root.livePreview && status !== Image.Null && status !== Image.Error
        source: root.imageCard ? Files.stampedUrl(root.cheapImage, root.modelData.generation) : ""
        sourceSize: root.decodeSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: if (status === Image.Error) console.warn("themes: card image unreadable path=" + root.cheapImage)
    }

    ThemePaletteStrip {
        objectName: "paletteStrip"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Theme.space.xxl
        palette: root.colors
    }

    Spinner {
        anchors.centerIn: parent
        visible: root.busy
    }
}
