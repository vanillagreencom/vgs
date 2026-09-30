import QtQuick
import qs.Commons

// A theme card's palette as one strip of equal blocks, every colour but
// the background, which the card itself shows. The card places and sizes
// it over its preview.
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
