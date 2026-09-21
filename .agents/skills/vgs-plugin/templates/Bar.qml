import QtQuick
import QtQuick.Layouts
import qs.Commons

// __NAME__: a replacement bar. The host assigns `shell`, `barConfig` and
// `screen` after creation. The bar owns layout only: it builds each widget
// from shell.widgets.entryUrl(id) with `bar`, `moduleName` and `settings`,
// and destroys a section's widgets before rebuilding it. widgetIds() is
// what the smoke reads to prove the widgets were built.
Item {
    id: bar

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

    function widgetIds() {
        const ids = [];
        for (const w of row.instances) ids.push(w.moduleName);
        return ids;
    }

    function entries() {
        const out = [];
        for (const section of ["left", "center", "right"])
            for (const e of (Array.isArray(layout[section]) ? layout[section] : []))
                if (e && typeof e.id === "string") out.push(e);
        return out;
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.controlGap
        property var instances: []

        function rebuild() {
            for (const item of instances) item.destroy();
            instances = [];
            if (bar.shell === null || bar.barConfig === null) return;
            const built = [];
            for (const entry of bar.entries()) {
                const url = bar.shell.widgets.entryUrl(entry.id);
                if (url === "") continue;
                const component = Qt.createComponent(url);
                if (component.status !== Component.Ready) { console.error("__ID__: widget " + entry.id + " failed: " + component.errorString()); continue; }
                const widget = component.createObject(row, { bar: bar, moduleName: entry.id, settings: entry });
                if (widget !== null) built.push(widget);
            }
            instances = built;
        }

        Component.onDestruction: { for (const item of instances) item.destroy(); }
    }

    onShellChanged: row.rebuild()
    onLayoutChanged: row.rebuild()
}
