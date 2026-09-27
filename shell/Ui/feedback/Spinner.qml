import QtQuick
import QtQuick.Shapes
import qs.Commons

// An indeterminate wait: a quarter arc turning over a faint ring. It turns
// while `running` holds and the theme's duration is above zero, so a
// reduced-motion theme shows the arc still.
Item {
    id: root

    property int size: Theme.spinner.size
    property bool running: visible

    implicitWidth: size
    implicitHeight: size

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: Theme.spinner.track
            fillColor: "transparent"
            strokeWidth: Theme.spinner.stroke
            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: (root.size - Theme.spinner.stroke) / 2
                radiusY: radiusX
                sweepAngle: 360
            }
        }
        ShapePath {
            strokeColor: Theme.spinner.color
            fillColor: "transparent"
            strokeWidth: Theme.spinner.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: (root.size - Theme.spinner.stroke) / 2
                radiusY: radiusX
                sweepAngle: 90
            }
        }

        RotationAnimation on rotation {
            from: 0
            to: 360
            duration: Theme.spinner.duration
            loops: Animation.Infinite
            running: root.running && Theme.spinner.duration > 0
        }
    }
}
