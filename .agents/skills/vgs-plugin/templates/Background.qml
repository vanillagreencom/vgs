import QtQuick
import qs.Commons

// __NAME__ background: drawn under every window on each screen, inside the
// core's background surface. The core assigns `shell` and `screen` after
// creation. Colours come from Color.
Item {
    id: root

    property var shell: null
    property var screen: null

    Rectangle {
        anchors.fill: parent
        color: Color.background
    }
}
