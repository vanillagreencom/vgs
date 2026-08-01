import QtQuick
import qs.Common
import qs.Widgets

// Modal sheet used by every Cloud Sync flow: scrim, centered card, fixed
// header/footer with a scrolling body between them.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property string confirmText: I18n.tr("Continue", "Default confirm button on a Cloud Sync dialog")
    property string cancelText: I18n.tr("Cancel", "Default cancel button on a Cloud Sync dialog")
    property bool confirmEnabled: true
    property bool confirmDestructive: false
    property bool showConfirm: true
    property bool showCancel: true
    property real dialogWidth: 560
    property real maxDialogHeight: 860
    property alias footerExtra: footerExtraLoader.sourceComponent

    // `.data` (not `.children`) so dialogs can also declare non-visual elements
    // such as Connections alongside their visible content.
    default property alias dialogContent: bodyColumn.data

    signal confirmed
    signal cancelled

    function close() {
        cancelled();
    }

    anchors.fill: parent
    z: 100

    // Scrim: clicking outside cancels, matching every other dismissable surface
    // in the shell.
    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha("#000000", 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: root.cancelled()
        }
    }

    StyledRect {
        id: card

        anchors.centerIn: parent
        // Clamped so a window narrower than the dialog cannot collapse it to a
        // negative size (which renders as nothing at all).
        width: Math.max(0, Math.min(root.dialogWidth, parent.width - Theme.spacingL * 2))
        height: Math.max(0, Math.min(root.maxDialogHeight, parent.height - Theme.spacingL * 2, headerColumn.implicitHeight + bodyFlick.contentHeight + footer.height + Theme.spacingXL * 2 + Theme.spacingL * 2))
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.borderColorStrong

        // Swallow clicks so the scrim's dismiss does not fire through the card.
        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: headerColumn

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.spacingXL
            anchors.bottomMargin: 0
            spacing: Theme.spacingXS

            StyledText {
                width: parent.width
                text: root.title
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightSectionHeader
                color: Theme.surfaceText
                wrapMode: Text.WordWrap
            }

            StyledText {
                visible: root.subtitle.length > 0
                width: parent.width
                text: root.subtitle
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.35
                lineHeightMode: Text.ProportionalHeight
            }
        }

        VgsFlickable {
            id: bodyFlick

            anchors.top: headerColumn.bottom
            anchors.topMargin: Theme.spacingL
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.spacingL
            anchors.leftMargin: Theme.spacingXL
            anchors.rightMargin: Theme.spacingXL
            clip: true
            contentWidth: width
            contentHeight: bodyColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: bodyColumn

                width: bodyFlick.width
                spacing: Theme.spacingL
                bottomPadding: Theme.spacingS
            }
        }

        Item {
            id: footer

            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.spacingXL
            anchors.topMargin: 0
            height: 36

            Loader {
                id: footerExtraLoader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                VgsButton {
                    visible: root.showCancel
                    text: root.cancelText
                    variant: "secondary"
                    buttonHeight: 36
                    onClicked: root.cancelled()
                }

                VgsButton {
                    visible: root.showConfirm
                    text: root.confirmText
                    enabled: root.confirmEnabled
                    buttonHeight: 36
                    backgroundColor: root.confirmDestructive ? Theme.error : Theme.primary
                    textColor: root.confirmDestructive ? Theme.background : Theme.primaryText
                    onClicked: root.confirmed()
                }
            }
        }
    }
}
