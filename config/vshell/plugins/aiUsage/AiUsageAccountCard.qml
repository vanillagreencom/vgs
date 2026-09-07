import QtQuick
import qs.Common
import qs.Widgets

// One account, whichever provider it belongs to and however many accounts that
// provider reported. The popout used to render a single account as a column of
// bare meters and several accounts as cards, so the same account changed shape
// when a second one appeared and neither layout carried the other's controls.
// There is one card now, and every account is one.
StyledRect {
    id: accountCard

    // The AiUsageWidget root. Supplies the formatting and colour helpers.
    property var host: null
    // One entry from a deck section's cards.
    property var account: null
    property bool expanded: false
    // Off when the popout already groups by provider under a section header.
    property bool showProviderIcon: true

    signal toggleExpanded
    signal hideRequested

    readonly property bool ok: !!accountCard.account && accountCard.account.ok === true
    readonly property var meters: (accountCard.host && accountCard.account)
        ? accountCard.host.metersFor(accountCard.account) : []

    height: cardColumn.implicitHeight + Theme.spacingM * 2
    radius: Theme.cornerRadius
    color: cardArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

    Behavior on height {
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Easing.OutCubic
        }
    }

    MouseArea {
        id: cardArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: accountCard.toggleExpanded()
    }

    Column {
        id: cardColumn
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingXS

        Item {
            width: parent.width
            height: Math.max(labelText.implicitHeight, planText.implicitHeight) + 5

            VgsIcon {
                id: providerBadge
                anchors.left: parent.left
                anchors.verticalCenter: labelText.verticalCenter
                name: accountCard.account ? accountCard.account.providerIcon : ""
                size: Theme.iconSizeSmall
                color: Theme.surfaceVariantText
                visible: accountCard.showProviderIcon
            }

            StyledText {
                id: labelText
                anchors.left: accountCard.showProviderIcon ? providerBadge.right : parent.left
                anchors.leftMargin: accountCard.showProviderIcon ? Theme.spacingXS : 0
                anchors.right: planText.left
                anchors.rightMargin: Theme.spacingS
                anchors.top: parent.top
                text: accountCard.account ? accountCard.account.label : ""
                elide: Text.ElideMiddle
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            // The plan yields to the hide button while the pointer is over the
            // card, so hiding an account is done where the account is rather
            // than on a settings page two taps away.
            StyledText {
                id: planText
                anchors.right: hideButton.visible ? hideButton.left : parent.right
                anchors.rightMargin: hideButton.visible ? Theme.spacingXS : 0
                anchors.verticalCenter: labelText.verticalCenter
                text: accountCard.ok ? (accountCard.account.plan || "") : "unavailable"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            VgsActionButton {
                id: hideButton
                anchors.right: parent.right
                anchors.verticalCenter: labelText.verticalCenter
                visible: cardArea.containsMouse
                iconName: "visibility_off"
                iconSize: Theme.iconSizeSmall
                buttonSize: 24
                iconColor: Theme.surfaceVariantText
                tooltipText: "Hide this account"
                onClicked: accountCard.hideRequested()
            }
        }

        Repeater {
            model: accountCard.expanded ? [] : accountCard.meters

            MeterRow {
                required property var modelData

                width: cardColumn.width
                host: accountCard.host
                meter: modelData
                ok: accountCard.ok
            }
        }

        Repeater {
            model: accountCard.expanded ? accountCard.meters : []

            MeterCard {
                required property var modelData

                width: cardColumn.width
                spacing: 2
                topPadding: Theme.spacingXS

                host: accountCard.host
                meter: modelData
                ok: accountCard.ok
                // A spend pool prints an amount; a rate-limit window prints its
                // reset. formatSpendExact answers for both, falling back to the
                // provider's own detail string.
                detailText: accountCard.host
                    ? (accountCard.host.formatSpendExact(modelData) || accountCard.host.resetLabel(modelData))
                    : ""
            }
        }

        // An account with no lanes at all is not a failure; the provider simply
        // reported no quota for it. Saying so beats an empty card.
        StyledText {
            visible: accountCard.ok && accountCard.meters.length === 0
            width: parent.width
            text: "No limits reported for this account."
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            visible: !!accountCard.account && !accountCard.ok
            width: parent.width
            text: (accountCard.account && accountCard.account.error) ? accountCard.account.error
                                                                    : "Usage unavailable"
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
