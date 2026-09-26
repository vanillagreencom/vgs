import QtQuick
import qs.Commons

// Base item every bar widget extends. The core assigns four properties
// after it builds the widget: `shell` (the widget's own scoped object),
// `bar` (the bar API), `moduleName` (the plugin id) and `settings` (the
// manifest defaults under the widget's layout entry).
Item {
    id: root

    property var shell: null
    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})

    readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

    // One setting with a fallback for a missing or null value.
    function setting(name, fallback) {
        const value = settings ? settings[name] : undefined;
        return value === undefined || value === null ? fallback : value;
    }
}
