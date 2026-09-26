import QtQuick
import QtQuick.Layouts
import qs.Commons

// The bar: three sections across the surface. Each section shows the bar's
// own built-in widgets first, in the order its `left`, `center` and `right`
// settings list them, then the plugin widgets the core mounts into the
// same container. The core owns every plugin widget; this file owns the
// geometry and the built-ins. `shell` and `screen` are assigned by the
// core after creation.
Item {
    id: bar

    property var shell: null
    property var screen: null

    readonly property color foreground: Color.bar.text
    readonly property color background: Color.bar.background
    readonly property string fontFamily: Style.font.family
    readonly property int barSize: Style.bar.sizeHorizontal

    readonly property Item leftSection: left
    readonly property Item centerSection: center
    readonly property Item rightSection: right

    // The built-in names one section lists, as text: a settings change
    // that leaves the list alone produces the same string, so the section
    // keeps its built-ins instead of rebuilding them. A name listed twice
    // in one section is drawn once, since each registers with the core
    // under `<section>-<name>`; the repeat is logged.
    function builtinsKey(section) {
        if (shell === null) return "[]";
        const names = shell.settings[section];
        if (!Array.isArray(names)) {
            console.warn("vgs.bar: setting " + section + " is not a list of built-in names: " + JSON.stringify(names));
            return "[]";
        }
        const once = names.filter((name, i) => names.indexOf(name) === i);
        if (once.length !== names.length)
            console.warn("vgs.bar: setting " + section + " lists a built-in twice, drawn once: " + JSON.stringify(names));
        return JSON.stringify(once);
    }
    readonly property string leftKey: builtinsKey("left")
    readonly property string centerKey: builtinsKey("center")
    readonly property string rightKey: builtinsKey("right")

    RowLayout {
        id: left
        spacing: Style.spacing.lg
        anchors { left: parent.left; leftMargin: Style.spacing.xl; top: parent.top; bottom: parent.bottom }
        Repeater { model: JSON.parse(bar.leftKey); Builtin { barItem: bar; section: "left" } }
    }
    RowLayout {
        id: center
        spacing: Style.spacing.lg
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; bottom: parent.bottom }
        Repeater { model: JSON.parse(bar.centerKey); Builtin { barItem: bar; section: "center" } }
    }
    RowLayout {
        id: right
        spacing: Style.spacing.lg
        anchors { right: parent.right; rightMargin: Style.spacing.xl; top: parent.top; bottom: parent.bottom }
        Repeater { model: JSON.parse(bar.rightKey); Builtin { barItem: bar; section: "right" } }
    }
}
