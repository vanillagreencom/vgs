import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// What a tooltip looks like, defined once.
//
// VGS has to host tooltips two ways (see docs/architecture/design-language.md
// § Tooltips): a bar or dock pill needs its own layer surface to draw outside a
// ~40px strip, while content inside a FloatingWindow can only use an in-window
// popup, because a Wayland client cannot know where its own toplevel sits on
// screen. Those are different *hosts*. They are not different *looks*, and
// before VGS-47 they had drifted into being: the layer-shell one used
// VgsSurfaceChrome with the BlurService border and popup surface color, the
// in-window one a bare Rectangle with a hardcoded 1px Theme.outlineMedium
// border and no glass. Both hosts now render this.
//
// Sizes stay parameters rather than constants: a pill tooltip and a settings
// tooltip genuinely have different room, and the two callers' existing metrics
// are preserved exactly rather than averaged into a new look.
VgsSurfaceChrome {
    id: root

    property string text: ""
    // Caps the whole body, padding included — not the text run.
    property real maxWidth: 300
    property real minWidth: 0

    implicitWidth: Math.min(maxWidth, Math.max(minWidth, label.implicitWidth + Theme.spacingM * 2))
    implicitHeight: label.implicitHeight + Theme.spacingS * 2

    radius: Theme.controlRadius
    surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
    borderColor: BlurService.borderColor
    borderWidth: BlurService.borderWidth

    StyledText {
        id: label

        anchors.centerIn: parent
        text: root.text
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        elide: Text.ElideRight
        width: Math.min(implicitWidth, root.maxWidth - Theme.spacingM * 2)
    }
}
