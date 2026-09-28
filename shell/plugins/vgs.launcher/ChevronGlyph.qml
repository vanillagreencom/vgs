import QtQuick

// The drawn right-pointing chevron a menu row ends with.
Item {
    id: glyph

    required property var look

    width: look.chevron.width
    height: look.chevron.height

    Repeater {
        model: 2
        Rectangle {
            required property int index
            width: glyph.height * glyph.look.chevron.length
            height: glyph.look.chevron.stroke
            radius: glyph.look.radius.full
            color: glyph.look.text.foreground
            antialiasing: true
            x: (glyph.width - width) / 2
            y: glyph.height / 2 - height / 2 + (index === 0 ? -1 : 1) * glyph.height * glyph.look.chevron.spread
            rotation: index === 0 ? 45 : -45
        }
    }
}
