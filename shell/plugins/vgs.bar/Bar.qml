import QtQuick
import QtQuick.Layouts
import qs.Commons

// The bar: three sections of widgets read from barConfig.layout. The core
// builds every widget through shell.widgets.create and hands it `bar`,
// `moduleName`, `settings` and its own `shell`; this file owns layout
// only. A section rebuilds when its own entry list changes, never on an
// unrelated configuration write.
Item {
    id: bar

    // The host assigns these after creation.
    property var shell: null
    property var barConfig: null
    property var screen: null

    readonly property color foreground: Color.bar.text
    readonly property color background: Color.bar.background
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: Style.bar.sizeHorizontal

    // Read straight from barConfig: a change handler runs before a dependent
    // binding re-evaluates, so a `layout` binding would be stale here.
    function layoutOf() { return barConfig && barConfig.layout ? barConfig.layout : {}; }

    function entries(section) {
        const list = layoutOf()[section];
        return Array.isArray(list) ? list.filter(e => e && typeof e.id === "string") : [];
    }

    component Section: RowLayout {
        id: section
        required property string name
        spacing: Style.spacing.controlGap
        property var instances: []
        property string builtKey: ""

        function rebuild() {
            if (bar.shell === null || bar.barConfig === null) return;
            const wanted = bar.entries(name);
            const key = JSON.stringify(wanted);
            if (key === builtKey) return;
            for (const item of instances) bar.shell.widgets.destroy(item);
            instances = [];
            const built = [];
            for (const entry of wanted) {
                const widget = bar.shell.widgets.create(entry.id, section, bar, entry);
                if (widget !== null) built.push(widget);
            }
            instances = built;
            builtKey = key;
        }

        Component.onDestruction: { for (const item of instances) if (bar.shell !== null) bar.shell.widgets.destroy(item); }
    }

    function rebuildAll() { left.rebuild(); center.rebuild(); right.rebuild(); }
    onShellChanged: rebuildAll()
    onBarConfigChanged: rebuildAll()

    Section { id: left; name: "left"; anchors { left: parent.left; leftMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
    Section { id: center; name: "center"; anchors.centerIn: parent }
    Section { id: right; name: "right"; anchors { right: parent.right; rightMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
}
