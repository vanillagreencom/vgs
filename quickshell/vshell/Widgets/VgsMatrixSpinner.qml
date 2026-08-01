import QtQuick
import qs.Common

Item {
    id: root

    property real size: 30
    property color color: Theme.primary
    property bool running: visible
    property int phase: 0

    readonly property real gap: Math.max(1, Math.round(size * 0.1))
    readonly property real cellSize: Math.max(2, (size - gap * 2) / 3)

    implicitWidth: size
    implicitHeight: size

    function pathPosition(index) {
        // Trace the perimeter before pulsing the center, like a tiny terminal cursor.
        const path = [0, 1, 2, 5, 8, 7, 6, 3, 4];
        return path.indexOf(index);
    }

    Timer {
        interval: 90
        repeat: true
        running: root.running
        onTriggered: root.phase = (root.phase + 1) % 9
    }

    Grid {
        anchors.centerIn: parent
        columns: 3
        spacing: root.gap

        Repeater {
            model: 9

            Rectangle {
                required property int index

                readonly property int trail: (root.phase - root.pathPosition(index) + 9) % 9

                width: root.cellSize
                height: root.cellSize
                radius: Math.max(1, Math.round(width * 0.2))
                color: root.color
                opacity: trail === 0 ? 1
                    : trail === 1 ? 0.68
                    : trail === 2 ? 0.38
                    : 0.13
                scale: trail === 0 ? 1
                    : trail === 1 ? 0.9
                    : 0.78

                Behavior on opacity {
                    NumberAnimation {
                        duration: 80
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on scale {
                    NumberAnimation {
                        duration: 80
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
