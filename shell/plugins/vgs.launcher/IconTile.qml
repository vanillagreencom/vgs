import QtQuick
import qs.Ui

// A rounded tile framing a row's icon: a Lucide name drawn with the
// launcher's own stroke and colour.
Rectangle {
    id: tile

    required property var look
    property string iconName: ""
    property bool active: false

    width: look.tile.size
    height: look.tile.size
    radius: look.tile.radius
    gradient: Gradient {
        GradientStop { position: 0; color: tile.active ? tile.look.tile.topActive : tile.look.tile.top }
        GradientStop { position: 1; color: tile.active ? tile.look.tile.bottomActive : tile.look.tile.bottom }
    }
    border.width: look.tile.borderWidth
    border.color: active ? look.tile.borderActive : look.tile.border

    Icon {
        anchors.centerIn: parent
        visible: tile.iconName.length > 0
        name: tile.iconName
        size: tile.look.tile.glyph
        stroke: tile.look.tile.stroke
        color: tile.look.text.foreground
        opacity: tile.active ? 1 : tile.look.tile.rest
    }
}
