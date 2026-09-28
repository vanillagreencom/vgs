import QtQuick

// The text caret, with a soft blink and a halo so it reads as light rather
// than a flat bar. `nudge()` holds it on while typing. It blinks only while
// the theme's motion scale is above 0, and otherwise stays on.
Rectangle {
    id: caret

    required property var look
    property bool running: visible
    // Accent while a search runs, the foreground otherwise.
    property bool lit: false
    readonly property bool blinking: running && look.motion.scale > 0

    width: look.caret.width
    radius: look.radius.full
    color: lit ? look.palette.accent : look.text.foreground

    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 4
        height: parent.height + parent.width * 2
        radius: caret.look.radius.full
        color: caret.lit ? caret.look.caret.halo : caret.look.caret.haloIdle
    }

    onBlinkingChanged: if (!blinking) opacity = 1

    function nudge() {
        opacity = 1;
        if (blinking) blink.restart();
    }

    SequentialAnimation on opacity {
        id: blink
        running: caret.blinking
        loops: Animation.Infinite
        PauseAnimation { duration: caret.look.motion.duration.caretHold }
        Anim { to: 0; duration: caret.look.motion.duration.short3; curve: caret.look.motion.curve.standard }
        PauseAnimation { duration: caret.look.motion.duration.caretGap }
        Anim { to: 1; duration: caret.look.motion.duration.short3; curve: caret.look.motion.curve.standard }
    }
}
