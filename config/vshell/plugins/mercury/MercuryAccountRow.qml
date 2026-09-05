import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryFormat.js" as Fmt

// One account: what it is called, what it holds, and — on request — the full
// account and routing numbers.
//
// The numbers are masked by default and the reveal is deliberately not sticky.
// The popout resets it every time it closes, so an account number cannot be
// left sitting on a bar that hangs over a shared screen.
Item {
    id: root

    required property var account
    property bool revealed: false

    signal revealToggled

    readonly property var nameParts: Fmt.accountLabel(root.account)
    readonly property string numberText: Fmt.accountNumberText(root.account, root.revealed)

    implicitHeight: card.height
    height: card.height

    StyledRect {
        id: card
        width: parent.width
        height: content.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Behavior on height {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }

        Column {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingXS

            RowLayout {
                width: parent.width
                spacing: Theme.spacingS

                VgsIcon {
                    name: Logic.accountIcon(root.account)
                    size: Theme.iconSize
                    color: Theme.primary
                    Layout.alignment: Qt.AlignVCenter
                }

                StyledText {
                    Layout.fillWidth: true
                    text: root.nameParts.name
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }

                StyledText {
                    visible: root.nameParts.suffix.length > 0
                    text: root.nameParts.suffix
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: Fmt.moneyPopout(root.account.currentBalance)
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }

                VgsActionButton {
                    iconName: root.revealed ? "visibility_off" : "visibility"
                    iconSize: Theme.iconSizeSmall
                    buttonSize: 26
                    iconColor: root.revealed ? Theme.primary : Theme.surfaceVariantText
                    visible: String(root.account.accountNumber || "").length > 0
                    tooltipText: root.revealed
                        ? I18n.tr("Hide the account number")
                        : I18n.tr("Show the account number")
                    onClicked: root.revealToggled()
                }
            }

            // The numbers, and a way to get them somewhere useful. Copying puts
            // the value in the clipboard, which VGS records in its history —
            // the same as any other copy, and the reason this is a button
            // rather than something the row does on its own.
            RowLayout {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.revealed && root.numberText.length > 0

                StyledText {
                    Layout.fillWidth: true
                    text: root.numberText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    isMonospace: true
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }

                StyledText {
                    visible: String(root.account.routingNumber || "").length > 0
                    text: I18n.tr("routing %1").arg(root.account.routingNumber)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    isMonospace: true
                }

                VgsActionButton {
                    iconName: "content_copy"
                    iconSize: Theme.iconSizeSmall
                    buttonSize: 26
                    iconColor: Theme.surfaceVariantText
                    tooltipText: I18n.tr("Copy the account number")
                    onClicked: {
                        Quickshell.execDetached([Paths.vshellCli, "cl", "copy",
                                                 String(root.account.accountNumber || "")]);
                        ToastService.showInfo(I18n.tr("Account number copied"),
                                              root.nameParts.name, "", "mercury-copy");
                    }
                }
            }
        }
    }
}
