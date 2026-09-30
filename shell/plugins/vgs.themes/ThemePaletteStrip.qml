import QtQuick
import qs.Commons

// A separable palette layer for a theme card. VGS-596 can move this layer
// without changing the preview body below it.
Row {
    id: root

    property var palette: null
    readonly property var keys: palette === null ? [] : Object.keys(palette).filter(key => key !== "background")

    Repeater {
        model: root.keys
        Rectangle {
            required property string modelData
            width: root.keys.length === 0 ? 0 : root.width / root.keys.length
            height: root.height
            color: Theme.toColor(root.palette[modelData])
        }
    }
}
