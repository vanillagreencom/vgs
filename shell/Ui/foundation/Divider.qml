import QtQuick
import qs.Commons

// A hairline between two blocks: horizontal by default, vertical when
// `vertical` holds. It sizes its own thickness; the parent sets the length.
Rectangle {
    id: root

    property bool vertical: false

    implicitWidth: vertical ? Theme.divider.thickness : 0
    implicitHeight: vertical ? 0 : Theme.divider.thickness
    color: Theme.divider.color
}
