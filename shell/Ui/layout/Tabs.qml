import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A row of tabs: `model` lists the tab texts and `currentIndex` the open
// one. The template owns the index, the left and right keys and the click;
// this file draws each tab and the indicator under the open one.
T.TabBar {
    id: root

    property var model: []

    implicitWidth: contentItem.implicitWidth
    implicitHeight: Theme.tabs.height
    spacing: Theme.tabs.gap

    contentItem: ListView {
        model: root.contentModel
        currentIndex: root.currentIndex
        orientation: ListView.Horizontal
        spacing: root.spacing
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.AutoFlickIfNeeded
        snapMode: ListView.SnapToItem
        highlightMoveDuration: Theme.motion.duration.fast
        highlightRangeMode: ListView.ApplyRange
        implicitWidth: contentWidth
    }

    background: Item {
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Theme.border.thin
            color: Theme.tabs.border
        }
    }

    Repeater {
        model: root.model
        T.TabButton {
            id: tab
            required property var modelData
            text: String(modelData)
            implicitWidth: implicitContentWidth + leftPadding + rightPadding
            implicitHeight: Theme.tabs.height
            leftPadding: Theme.space.xs
            rightPadding: Theme.space.xs
            hoverEnabled: true
            PointerCursor {}
            Accessible.name: text

            contentItem: Label {
                role: "button"
                text: tab.text
                color: tab.checked || tab.hovered ? Theme.tabs.active : Theme.tabs.foreground
                verticalAlignment: Text.AlignVCenter
                Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
            }

            background: Item {
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Theme.tabs.indicator
                    color: Theme.tabs.indicatorColor
                    visible: tab.checked
                }
                FocusRing { target: tab }
            }
        }
    }
}
