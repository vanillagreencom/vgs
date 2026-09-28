import QtQuick

// The drawn magnifier at the start of the search field.
Item {
    id: glyph

    required property var look
    readonly property real stroke: look.search.stroke

    width: look.search.size
    height: look.search.size

    Rectangle {
        width: glyph.width * 0.72
        height: width
        radius: glyph.look.radius.full
        color: "transparent"
        border.width: glyph.stroke
        border.color: glyph.look.text.foreground
    }
    Rectangle {
        width: glyph.width * 0.36
        height: glyph.stroke
        radius: glyph.look.radius.full
        color: glyph.look.text.foreground
        rotation: 45
        x: glyph.width * 0.6
        y: glyph.width * 0.76
        transformOrigin: Item.Center
    }
}
