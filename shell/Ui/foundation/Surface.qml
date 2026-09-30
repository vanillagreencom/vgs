import QtQuick
import qs.Commons

// A panel background at one level: `base`, `raised` or `sunken` name a
// group of `Theme.surface.level`. A level the theme lacks is logged and
// drawn as base. It places nothing: a container lays its content out with
// `Pane`, which owns the inset and clears the rounded corner.
Rectangle {
    id: root

    property string level: "base"
    readonly property var tokens: levelOf(level)

    function levelOf(name) {
        const found = Theme.surface.level[name];
        if (found !== undefined) return found;
        console.error("Surface: no level named " + JSON.stringify(name));
        return Theme.surface.level.base;
    }

    color: tokens.background
    border.color: tokens.border
    border.width: Theme.surface.border
    radius: Theme.surface.radius
}
