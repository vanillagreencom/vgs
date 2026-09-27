pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// A two-segment capsule for a switcher's scopeToggle or sourceToggle slot. It owns no state: the switcher binds
// activeIndex and handles picked.
Rectangle {
    id: pill

    // The segment labels, in order.
    property var labels: []
    property int activeIndex: 0

    // Emitted with the clicked segment's index when it is not the active one.
    signal picked(int index)

    width: segments.width + Theme.spacingXXS * 2
    height: segments.height + Theme.spacingXXS * 2
    radius: height / 2
    color: Theme.withAlpha(Theme.background, 0.45)
    border.width: 1
    border.color: Theme.withAlpha(Theme.surfaceText, 0.2)

    // Consume clicks on the capsule's padding so near misses cannot fall through to click-away dismissal.
    MouseArea {
        anchors.fill: parent
    }

    Row {
        id: segments
        anchors.centerIn: parent

        Repeater {
            model: pill.labels

            Rectangle {
                id: segment

                required property int index
                required property var modelData
                readonly property bool active: pill.activeIndex === segment.index

                width: segmentLabel.width + Theme.spacingM * 2
                height: segmentLabel.height + Theme.spacingXS * 2
                radius: height / 2
                color: segment.active ? Theme.withAlpha(Theme.surfaceText, 0.22) : "transparent"

                StyledText {
                    id: segmentLabel
                    anchors.centerIn: parent
                    text: segment.modelData
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    opacity: segment.active ? 1 : 0.7
                }

                // Clicking selects the labeled segment; the active one is a no-op.
                MouseArea {
                    anchors.fill: parent
                    onClicked: if (!segment.active) pill.picked(segment.index)
                }
            }
        }
    }
}
