pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Palette and per-surface colour roles. Plugins read these instead of
// literal colours so one theme file restyles every surface. Values come
// from the user's theme file when it exists; the defaults below stand
// otherwise.
Singleton {
    id: root

    readonly property string themePath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/vgs/theme.json"

    FileView {
        path: root.themePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()

        JsonAdapter {
            id: theme
            property string foreground: "#cacccc"
            property string background: "#101315"
            property string accent: "#8fbcbb"
            property string urgent: "#a55555"
            property string muted: "#707880"
        }
    }

    readonly property color foreground: theme.foreground
    readonly property color background: theme.background
    readonly property color accent: theme.accent
    readonly property color urgent: theme.urgent
    readonly property color muted: theme.muted

    readonly property QtObject bar: QtObject {
        readonly property color background: root.background
        readonly property color text: root.foreground
        readonly property color active: root.accent
    }
}
