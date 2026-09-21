import QtQuick
import QtQuick.Layouts
import qs.Commons

// __NAME__: a replacement bar. The host assigns `shell`, `barConfig` and
// `screen` after creation. The core builds every widget through
// shell.widgets.create and hands it its own properties; this file owns
// layout only and rebuilds when its entry list changes.
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

    // Read straight from barConfig: a change handler runs before a dependent
    // binding re-evaluates, so a `layout` binding would be stale here.
    function layoutOf() { return barConfig && barConfig.layout ? barConfig.layout : {}; }

    function entries() {
        const out = [];
        for (const section of ["left", "center", "right"])
            for (const e of (Array.isArray(layoutOf()[section]) ? layoutOf()[section] : []))
                if (e && typeof e.id === "string") out.push(e);
        return out;
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.controlGap
        property var instances: []
        property string builtKey: ""

        function rebuild() {
            if (bar.shell === null || bar.barConfig === null) return;
            const wanted = bar.entries();
            const key = JSON.stringify(wanted);
            if (key === builtKey) return;
            for (const item of instances) bar.shell.widgets.destroy(item);
            instances = [];
            const built = [];
            for (const entry of wanted) {
                const widget = bar.shell.widgets.create(entry.id, row, bar, entry);
                if (widget !== null) built.push(widget);
            }
            instances = built;
            builtKey = key;
        }

        Component.onDestruction: { for (const item of instances) if (bar.shell !== null) bar.shell.widgets.destroy(item); }
    }

    onShellChanged: row.rebuild()
    onBarConfigChanged: row.rebuild()
}
