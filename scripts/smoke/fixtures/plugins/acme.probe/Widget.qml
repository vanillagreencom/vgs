import QtQuick
import qs.Ui
BarWidget {
    moduleName: "acme.probe"
    implicitWidth: 10
    implicitHeight: barSize
    readonly property bool hasCompositor: shell !== null && shell.compositor !== undefined && typeof shell.compositor.focusWorkspace === "function"
    readonly property bool tagsAreArray: Array.isArray(settings.tags)
    readonly property string label: String(setting("label", ""))
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    readonly property string currentScreen: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    // The widget's index among its section's children; -1 with no parent.
    readonly property int layoutIndex: {
        if (parent === null) return -1;
        for (let i = 0; i < parent.children.length; i++)
            if (parent.children[i] === this) return i;
        return -1;
    }
    function setLabel(value) { return shell.configure.set("label", value); }
}
