import QtQuick
import qs.Commons

// Base item every bar widget extends. The bar host injects three properties
// into each widget slot: `bar` (the bar API), `moduleName` (the plugin id)
// and `settings` (the widget's inline layout entry).
Item {
    id: root

    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})

    readonly property bool vertical: bar ? bar.vertical : false
    readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

    // One inline setting with a fallback for a missing or null value.
    function setting(name, fallback) {
        const value = settings ? settings[name] : undefined;
        return value === undefined || value === null ? fallback : value;
    }
}
