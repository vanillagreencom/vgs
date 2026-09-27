import QtQuick
import QtQuick.Shapes
import qs.Commons
import "../icons/Lucide.js" as Lucide

// One Lucide icon by name, drawn from its path data with the curve
// renderer. The stroke is `stroke` in absolute pixels whatever the size,
// so a 14 pixel icon and a 24 pixel icon carry the same line weight: the
// shape is drawn in the data's box and scaled as an item, and the stroke
// width is divided by the same factor. The item transform, not the path's
// own `scale`, is what keeps a stroke under one unit visible: measured
// with qmltestrunner on Qt 6.11.2 on 2026-09-26, a 0.75 unit stroke on a
// path scaled by 2 drew nothing, and the same stroke under an item scale
// drew its two rows. A name the data lacks is logged and draws nothing.
Item {
    id: root

    property string name: ""
    property int size: Theme.icon.size.md
    property color color: Theme.color.text
    property real stroke: Theme.icon.stroke
    readonly property var paths: pathsOf(name)
    readonly property real factor: size / Lucide.VIEWBOX

    function pathsOf(wanted) {
        const found = Lucide.ICONS[wanted];
        if (found !== undefined) return found;
        if (wanted !== "") console.error("Icon: no icon named " + JSON.stringify(wanted));
        return ["", ""];
    }

    implicitWidth: size
    implicitHeight: size

    Shape {
        width: Lucide.VIEWBOX
        height: Lucide.VIEWBOX
        transform: Scale { xScale: root.factor; yScale: root.factor }
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.color
            fillColor: "transparent"
            strokeWidth: root.stroke / root.factor
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.paths[0] }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: root.color
            PathSvg { path: root.paths[1] }
        }
    }
}
