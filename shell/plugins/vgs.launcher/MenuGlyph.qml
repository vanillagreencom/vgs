import QtQuick

// The drawn menu glyph: two bars of unequal length that turn into a close
// cross while `open`.
Item {
    id: glyph

    required property var look
    property bool open: false
    property real emphasis: look.menuGlyph.idle
    property real openAmount: open ? 1 : 0
    Behavior on openAmount {
        Anim { duration: glyph.look.motion.duration.medium4; curve: glyph.look.motion.curve.emphasizedDecel }
    }

    width: look.menuGlyph.size
    height: look.menuGlyph.size

    readonly property real bar: look.menuGlyph.bar
    readonly property real gap: look.menuGlyph.gap

    Rectangle {
        width: glyph.width
        height: glyph.bar
        radius: glyph.look.radius.full
        color: glyph.look.text.foreground
        opacity: glyph.emphasis
        y: glyph.height / 2 - glyph.gap - height / 2 + glyph.gap * glyph.openAmount
        rotation: 45 * glyph.openAmount
    }
    Rectangle {
        width: glyph.width * (glyph.look.menuGlyph.short + (1 - glyph.look.menuGlyph.short) * glyph.openAmount)
        height: glyph.bar
        radius: glyph.look.radius.full
        color: glyph.look.text.foreground
        opacity: glyph.emphasis
        x: glyph.width - width
        y: glyph.height / 2 + glyph.gap - height / 2 - glyph.gap * glyph.openAmount
        rotation: -45 * glyph.openAmount
    }
}
