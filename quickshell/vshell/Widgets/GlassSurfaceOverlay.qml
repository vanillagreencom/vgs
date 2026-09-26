import QtQuick
import qs.Common

// Glass rim and interior sheen share a shader pass. Nested panels should disable rimEnabled to avoid interior borders.
Item {
    id: root

    property bool active: Theme.popupGlassEffect
    property real radius: Theme.cornerRadius
    property real borderWidth: 1
    property bool rimEnabled: true
    property real sheenOpacity: 1

    visible: active
    enabled: false

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("../Shaders/qsb/glass_rim.frag.qsb")

        property real widthPx: width
        property real heightPx: height
        property real radiusPx: root.radius
        property real rimWidthPx: root.rimEnabled ? Math.max(0, root.borderWidth) : 0
        property vector4d rimTopColor: Qt.vector4d(Theme.glassRimTopColor.r, Theme.glassRimTopColor.g, Theme.glassRimTopColor.b, Theme.glassRimTopColor.a)
        property vector4d rimBottomColor: Qt.vector4d(Theme.glassRimBottomColor.r, Theme.glassRimBottomColor.g, Theme.glassRimBottomColor.b, Theme.glassRimBottomColor.a)
        property vector4d sheenTopColor: Qt.vector4d(Theme.glassSheenTopColor.r, Theme.glassSheenTopColor.g, Theme.glassSheenTopColor.b, Theme.glassSheenTopColor.a * root.sheenOpacity)
        property vector4d sheenBottomColor: Qt.vector4d(Theme.glassSheenBottomColor.r, Theme.glassSheenBottomColor.g, Theme.glassSheenBottomColor.b, Theme.glassSheenBottomColor.a * root.sheenOpacity)
    }
}
