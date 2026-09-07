import QtQuick
import qs.Common
import qs.Widgets

// A provider's own mark, with the Material symbol behind it.
//
// The marks are filled WHITE, not currentColor. Qt's SVG renderer has no CSS
// context for currentColor and paints it black, and colorising a black source
// does not help: MultiEffect's colorisation preserves luminance, so black stays
// black whatever colour is asked for. A white source colorises to the requested
// colour exactly, which is why the shell's own matrix-logo-white.svg is white.
//
// The fallback is not decoration: a provider added to the catalog before its
// mark is shipped would otherwise take an empty slot on the bar, and an empty
// slot is indistinguishable from a provider that answered nothing.
Item {
    id: root

    // The AiUsageWidget root, or any host exposing the provider catalog.
    property var host: null
    property string provider: ""
    property int size: Theme.iconSizeSmall
    property color color: Theme.surfaceText

    readonly property string asset: root.host ? root.host.providerAsset(root.provider) : ""
    readonly property string symbol: root.host ? root.host.providerIcon(root.provider) : ""

    implicitWidth: root.size
    implicitHeight: root.size

    VgsSVGIcon {
        anchors.centerIn: parent
        visible: root.asset !== ""
        // Resolved beside this file: a user override loads the plugin from
        // ~/.config/vshell/plugins, where any shell-relative path is wrong.
        source: root.asset === "" ? "" : Qt.resolvedUrl(root.asset)
        size: root.size
        colorOverride: root.color
    }

    VgsIcon {
        anchors.centerIn: parent
        visible: root.asset === ""
        name: root.symbol
        size: root.size
        color: root.color
    }
}
