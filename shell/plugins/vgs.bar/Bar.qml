import QtQuick
import QtQuick.Layouts
import qs.Commons

// The bar: three sections of widgets read from barConfig.layout. Each
// widget is a bar-widget plugin loaded through `shell.widgets`, given the
// three properties every widget expects, and destroyed with its section
// when the layout changes. The bar owns layout only; a widget owns its
// content and its own state.
Item {
    id: bar

    // The host assigns these after creation; the sections build once both
    // `shell` and `barConfig` are present and rebuild when the layout changes.
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

    readonly property var layout: barConfig && barConfig.layout ? barConfig.layout : ({})

    // Ids of the widgets built into the three sections, left to right.
    function widgetIds() {
        const ids = [];
        for (const section of [left, center, right])
            for (const w of section.instances) ids.push(w.moduleName);
        return ids;
    }

    function entries(section) {
        const list = layout[section];
        return Array.isArray(list) ? list.filter(e => e && typeof e.id === "string") : [];
    }

    component Section: RowLayout {
        id: section
        required property string name
        spacing: Style.spacing.controlGap
        property var instances: []

        function rebuild() {
            for (const item of instances) item.destroy();
            instances = [];
            if (bar.shell === null || bar.barConfig === null) return;
            const built = [];
            for (const entry of bar.entries(name)) {
                const url = bar.shell.widgets.entryUrl(entry.id);
                if (url === "") { console.warn("bar: " + name + " names " + entry.id + ", which is not an enabled bar widget"); continue; }
                const component = Qt.createComponent(url);
                if (component.status !== Component.Ready) { console.error("bar: widget " + entry.id + " failed: " + component.errorString()); continue; }
                const widget = component.createObject(section, { bar: bar, moduleName: entry.id, settings: entry });
                if (widget === null) { console.error("bar: widget " + entry.id + " created no object"); continue; }
                built.push(widget);
            }
            instances = built;
        }

        Component.onCompleted: rebuild()
        Component.onDestruction: { for (const item of instances) item.destroy(); }
    }

    function rebuildAll() { left.rebuild(); center.rebuild(); right.rebuild(); }
    onShellChanged: rebuildAll()
    onLayoutChanged: rebuildAll()

    Section { id: left; name: "left"; anchors { left: parent.left; leftMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
    Section { id: center; name: "center"; anchors.centerIn: parent }
    Section { id: right; name: "right"; anchors { right: parent.right; rightMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
}
