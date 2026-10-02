import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A row of tabs: `model` lists the tab texts and `currentIndex` the open
// one. The template owns the index, the left and right keys and the click;
// this file draws each tab, its label centred `tabs.paddingX` in from each
// side, and the indicator under the open one. Hover lifts a closed tab's
// label, a press fills the tab, and a disabled row fades.
T.TabBar {
    id: root

    property var model: []

    implicitWidth: contentItem.implicitWidth
    implicitHeight: Theme.tabs.height
    spacing: Theme.tabs.gap
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.opacity.disabled
    Keys.onPressed: event => { event.accepted = nav.handle(event); }

    property KeyNav nav: KeyNav {
        count: root.count
        currentIndex: root.currentIndex
        orientation: "horizontal"
        wrap: true
        onMoved: index => root.currentIndex = index
    }

    contentItem: ListView {
        model: root.contentModel
        currentIndex: root.currentIndex
        orientation: ListView.Horizontal
        spacing: root.spacing
        boundsBehavior: Flickable.StopAtBounds
        acceptedButtons: Qt.NoButton
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
        // keyboard-path: the tab bar is one tab stop and its arrow keys choose tabs
        T.TabButton {
            id: tab
            required property var modelData
            readonly property bool selectedFocus: root.visualFocus && checked
            text: String(modelData)
            implicitWidth: implicitContentWidth + leftPadding + rightPadding
            implicitHeight: Theme.tabs.height
            leftPadding: Theme.tabs.paddingX
            rightPadding: Theme.tabs.paddingX
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            PointerCursor {}
            Accessible.name: text

            contentItem: Label {
                role: "button"
                text: tab.text
                color: tab.checked ? Theme.tabs.active : tab.hovered || tab.down ? Theme.tabs.hover : Theme.tabs.foreground
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
            }

            background: Rectangle {
                color: tab.down ? Theme.tabs.pressed : "transparent"
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Theme.tabs.indicator
                    color: Theme.tabs.indicatorColor
                    visible: tab.checked
                }
                FocusRing { target: tab; visible: tab.selectedFocus }
            }
        }
    }
}
