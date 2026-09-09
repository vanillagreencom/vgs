import QtQuick
import qs.Common
import qs.Widgets

// The provider filter: which providers the bar counts and this popout lists.
//
// It replaced a row of one button per provider that SELECTED a single one.
// That row could only ever show one provider's accounts, it grew a column
// narrower every time a provider was added, and "which provider am I looking
// at" and "which provider is on the bar" were the same setting, so looking at
// Codex moved the bar off Claude. This is a filter instead: several providers
// at once, all of them by default, and looking at something changes nothing.
Column {
    id: root

    // The AiUsageWidget root. Supplies provider identity and the current filter.
    property var host: null
    property bool expanded: false

    signal providerToggled(string provider)
    signal allRequested
    signal setupRequested(string provider)
    signal moveRequested(string provider, int delta)

    spacing: Theme.spacingXS

    // Listed in the order the bar uses, not the catalog's, so the arrows move a
    // row to where its slot will actually be.
    readonly property var providers: root.host ? root.host.filterOrder() : []

    StyledRect {
        id: trigger

        width: parent.width
        height: 36
        radius: Theme.cornerRadius
        color: triggerArea.containsMouse || root.expanded
            ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

        VgsIcon {
            id: filterIcon
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            name: "filter_list"
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.left: filterIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: chevron.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: root.host ? root.host.filterLabel() : ""
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        VgsIcon {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            name: "expand_more"
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
            rotation: root.expanded ? 180 : 0

            Behavior on rotation {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Easing.OutCubic
                }
            }
        }

        MouseArea {
            id: triggerArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expanded = !root.expanded
        }
    }

    // Opens in place rather than over the popout. A layered menu inside a
    // layer-shell flyout has to fight the flyout for dismissal and focus, and
    // this list is four rows.
    StyledRect {
        id: panel

        width: parent.width
        height: root.expanded ? panelColumn.implicitHeight + Theme.spacingS * 2 : 0
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        clip: true
        visible: height > 0

        Behavior on height {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }

        Column {
            id: panelColumn
            width: parent.width
            y: Theme.spacingS
            spacing: 0

            AiUsageFilterRow {
                width: panelColumn.width
                label: "All providers"
                checked: root.host ? root.host.filterIsAll() : true
                onToggled: root.allRequested()
            }

            Rectangle {
                width: panelColumn.width - Theme.spacingM * 2
                x: Theme.spacingM
                height: 1
                color: Theme.outlineMedium
            }

            Repeater {
                model: root.providers

                AiUsageFilterRow {
                    required property string modelData

                    width: panelColumn.width
                    label: root.host ? root.host.providerName(modelData) : modelData
                    host: root.host
                    provider: modelData
                    checked: root.host ? root.host.filterHas(modelData) : false
                    // Every provider has somewhere to point its accounts at,
                    // whether that is a key or an extra config directory, so
                    // every row offers the way in rather than only the ones
                    // that happen to need a secret.
                    showSetup: true
                    showMove: true
                    canMoveUp: root.host ? root.host.canMoveProvider(modelData, -1) : false
                    canMoveDown: root.host ? root.host.canMoveProvider(modelData, 1) : false
                    onToggled: root.providerToggled(modelData)
                    onSetupClicked: root.setupRequested(modelData)
                    onMoveUp: root.moveRequested(modelData, -1)
                    onMoveDown: root.moveRequested(modelData, 1)
                }
            }
        }
    }
}
