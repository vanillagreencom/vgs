import QtQuick
import qs.Ui
import "Tick.js" as Tick
BarWidget {
    readonly property string format: String(setting("format", ""))
    readonly property string sibling: Tick.VALUE
    implicitWidth: 20
    implicitHeight: barSize
    // The widget's index among its section's children, the order a row
    // layout draws them in; -1 with no parent.
    readonly property int layoutIndex: {
        if (parent === null) return -1;
        for (let i = 0; i < parent.children.length; i++)
            if (parent.children[i] === this) return i;
        return -1;
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
