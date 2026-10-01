import QtQuick
import qs.Commons

// The mask of a menu's or a select's list, internal to the module: a hidden
// rounded rectangle the list's own layer reads through a MultiEffect, as
// AngledCard's content reads its shape. Its corner is the window's drawn
// `menu.radius`, clamped to half the window's smaller side, less the
// border: the curve of the list's interior. A list that fills the interior
// is cut to it, and one the corner keeps lower (Theme.menuListInset) to a
// shape inside it, so a row, its highlight, a chosen row's fill and the
// scroll bar stay inside the curve at every scroll position, a row half
// scrolled past an edge included. It fills the list it masks; while the
// corner is square, `cuts` is false, the list draws no layer and its own
// rectangular clip is the whole cut.
Rectangle {
    id: root

    // The window the list sits in, inside its border.
    required property real frameWidth
    required property real frameHeight
    readonly property bool cuts: radius > 0

    radius: Math.max(0, Math.min(Theme.menu.radius, frameWidth / 2, frameHeight / 2) - Theme.border.thin)
    visible: false
    layer.enabled: cuts
    layer.smooth: true
}
