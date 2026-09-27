import QtQuick
import qs.Ui
import "Tick.js" as Tick
BarWidget {
    readonly property string format: String(setting("format", ""))
    readonly property string sibling: Tick.VALUE
    implicitWidth: 20
    implicitHeight: barSize
    // The value of a file first read now, or the loader's error text.
    function lazy() {
        const component = Qt.createComponent(Qt.resolvedUrl("Lazy.qml"));
        if (component.status !== Component.Ready) return "error: " + component.errorString();
        const object = component.createObject(null);
        const value = object.value;
        object.destroy();
        return value;
    }
}
