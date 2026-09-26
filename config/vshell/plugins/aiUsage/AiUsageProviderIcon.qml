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

    // A Material Symbol draws its body inside about three quarters of the size
    // it is asked for — the font reserves the rest as padding. A mark shipped
    // beside this file fills 95% of its own viewBox, which a test pins, so at
    // the same requested size it renders a quarter larger than the Material
    // glyph next to it on the bar. This is the ratio that puts the two at one
    // optical size. It is one number for every mark rather than a scale factor
    // per drawing, which is what makes it survive replacing the artwork.
    readonly property real materialGlyphFill: 0.75
    readonly property real markArtworkFill: 0.95
    readonly property int markSize: Math.round(root.size * (materialGlyphFill / markArtworkFill))

    VgsSVGIcon {
        anchors.centerIn: parent
        visible: root.asset !== ""
        // Resolved beside this file: a user override loads the plugin from
        // ~/.config/vshell/plugins, where any shell-relative path is wrong.
        source: root.asset === "" ? "" : Qt.resolvedUrl(root.asset)
        size: root.markSize
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
