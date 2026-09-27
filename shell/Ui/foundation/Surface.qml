import QtQuick
import qs.Commons

// A panel background at one level: `base`, `raised` or `sunken` name a
// group of `Theme.surface.level`. A level the theme lacks is logged and
// drawn as base. `padding` is the inset children lay out inside.
Rectangle {
    id: root

    property string level: "base"
    property int padding: Theme.surface.padding
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
