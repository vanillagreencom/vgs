pragma Singleton
import QtQuick
import Quickshell

// Structural tokens: spacing, type scale and bar size. Plugins read these
// instead of literal pixels so one change restyles every surface.
Singleton {
    id: root

    readonly property int cornerRadius: 6
    readonly property string fontFamily: "monospace"

    function space(units) { return Math.round(units * 4); }

    readonly property QtObject spacing: QtObject {
        readonly property int xs: 3
        readonly property int sm: 4
        readonly property int md: 6
        readonly property int lg: 8
        readonly property int xl: 10
        readonly property int controlGap: 8
        readonly property int controlPaddingX: 10
    }

    readonly property QtObject font: QtObject {
        readonly property string family: root.fontFamily
        readonly property int size: 13
        readonly property int small: 11
    }

    readonly property QtObject bar: QtObject {
        readonly property int sizeHorizontal: 26
        readonly property int sizeVertical: 28
    }
}
