import QtQuick
import qs.Ui
import "Tick.js" as Tick
BarWidget {
    id: tick
    readonly property string format: String(setting("format", ""))
    readonly property string sibling: Tick.VALUE
    // The presses that reached the widget, so a row proves a click on the
    // bar was not taken by a surface above it.
    property int presses: 0
    implicitWidth: 20
    implicitHeight: barSize
    MouseArea {
        anchors.fill: parent
        onPressed: tick.presses += 1
    }
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
