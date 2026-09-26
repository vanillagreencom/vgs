import QtQuick
import qs.Ui
BarWidget {
    implicitWidth: 10
    implicitHeight: barSize
    readonly property bool hasCompositor: shell !== null && shell.compositor !== undefined && typeof shell.compositor.focusWorkspace === "function"
    readonly property bool tagsAreArray: Array.isArray(settings.tags)
    readonly property string label: String(setting("label", ""))
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    readonly property string currentScreen: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    function setLabel(value) { return shell.configure.set("label", value); }
}
