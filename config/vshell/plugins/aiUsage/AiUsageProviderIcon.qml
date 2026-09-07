import QtQuick
import qs.Common
import qs.Widgets

// A provider's own mark, with the Material symbol behind it.
//
// The marks are monochrome and drawn with fill="currentColor", which Qt's SVG
// renderer has no context for and paints BLACK — invisible on a dark bar. The
// colour is therefore always applied as a colorisation, never left to the file.
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
