import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Widgets

// Confirm installation of a persistent passwordless-sudo rule.
// Start with Cancel selected. Only confirmation can persist the do-not-ask-again choice.
VgsModal {
    id: root

    readonly property int cancelButton: 0
    readonly property int confirmButton: 1

    // Rule path reported by sudo-toggle status, shown for inspection and external removal. Empty until the probe returns.
    property string dropinPath: ""
    property bool dontAskAgain: false
    property int selectedButton: cancelButton

    // `dontAskAgain` is passed rather than read back off this object so a
    // handler cannot observe it after a reset.
    signal confirmed(bool dontAskAgain)
    signal cancelled

    function promptFor(path) {
        root.dropinPath = path || "";
        root.dontAskAgain = false;
        root.selectedButton = root.cancelButton;
        root.open();
    }

    function _finish(button) {
        const grant = button === root.confirmButton;
        const skipFuture = grant && root.dontAskAgain;
        root.close();
        if (grant)
            root.confirmed(skipFuture);
        else
            root.cancelled();
    }

    layerNamespace: "vshell:sudo-grant-confirm"
    shouldBeVisible: false
    allowStacking: true
    useOverlayLayer: true
    shouldHaveFocus: true
    enableShadow: true
    modalWidth: 460
    modalHeight: contentLoader.item ? contentLoader.item.implicitHeight + Theme.popoutPadding * 2 : 320

    onBackgroundClicked: root._finish(root.cancelButton)

    onOpened: Qt.callLater(function () {
        modalFocusScope.forceActiveFocus();
        modalFocusScope.focus = true;
    })

    modalFocusScope.Keys.onPressed: function (event) {
        switch (event.key) {
        case Qt.Key_Escape:
            root._finish(root.cancelButton);
            event.accepted = true;
            break;
        case Qt.Key_Left:
        case Qt.Key_Up:
            root.selectedButton = root.cancelButton;
            event.accepted = true;
            break;
        case Qt.Key_Right:
        case Qt.Key_Down:
            root.selectedButton = root.confirmButton;
            event.accepted = true;
            break;
        case Qt.Key_Tab:
            root.selectedButton = root.selectedButton === root.cancelButton ? root.confirmButton : root.cancelButton;
            event.accepted = true;
            break;
        case Qt.Key_Space:
            root.dontAskAgain = !root.dontAskAgain;
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:

            root._finish(root.selectedButton);
            event.accepted = true;
            break;
        }
    }

    content: Component {
        Item {
            anchors.fill: parent
            implicitHeight: mainColumn.implicitHeight

            Column {
                id: mainColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.popoutPadding
                spacing: Theme.spacingM

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    VgsIcon {
                        name: "gpp_maybe"
                        size: Theme.iconSize
                        color: Theme.error
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: I18n.tr("Grant passwordless sudo?")
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Theme.fontWeightSectionHeader
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("This installs a permanent NOPASSWD rule for your user. It has no expiry: until you revoke it here, every command run with sudo — by you or by anything running as you — proceeds without asking for your password.")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                StyledRect {
                    width: parent.width
                    height: pathColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.controlRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Theme.borderColor
                    visible: root.dropinPath !== ""

                    Column {
                        id: pathColumn

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXXS

                        StyledText {
                            width: parent.width
                            text: I18n.tr("Rule file")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            width: parent.width
                            text: root.dropinPath
                            isMonospace: true
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WrapAnywhere
                        }
                    }
                }

                VgsToggle {
                    width: parent.width
                    horizontalPadding: 0
                    text: I18n.tr("Don't ask me again")
                    description: I18n.tr("Grant immediately next time, without this confirmation. Revocation is never confirmed either way.")
                    checked: root.dontAskAgain
                    onToggled: checked => root.dontAskAgain = checked
                }

                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacingS


                    Rectangle {
                        width: Math.max(110, cancelLabel.contentWidth + Theme.spacingL * 2)
                        height: 40
                        radius: Theme.controlRadius
                        color: cancelArea.containsMouse ? Theme.surfaceHover : "transparent"
                        border.color: root.selectedButton === root.cancelButton ? Theme.focusRing : Theme.secondaryOutline
                        border.width: root.selectedButton === root.cancelButton ? Theme.focusRingWidth : 1

                        StyledText {
                            id: cancelLabel

                            anchors.centerIn: parent
                            text: I18n.tr("Cancel")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        MouseArea {
                            id: cancelArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._finish(root.cancelButton)
                        }
                    }

                    // Keep the grant action out of the default selection.
                    Rectangle {
                        width: Math.max(150, confirmLabel.contentWidth + Theme.spacingL * 2)
                        height: 40
                        radius: Theme.controlRadius
                        color: confirmArea.containsMouse ? Qt.darker(Theme.error, 1.1) : Theme.error
                        border.color: root.selectedButton === root.confirmButton ? Theme.focusRing : Theme.withAlpha(Theme.error, 0)
                        border.width: root.selectedButton === root.confirmButton ? Theme.focusRingWidth : 0

                        StyledText {
                            id: confirmLabel

                            anchors.centerIn: parent
                            text: I18n.tr("Grant permanently")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.primaryText
                        }

                        MouseArea {
                            id: confirmArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._finish(root.confirmButton)
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }
                    }
                }
            }

            VgsActionButton {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                iconName: "close"
                iconSize: Theme.iconSize - 4
                iconColor: Theme.surfaceText
                onClicked: root._finish(root.cancelButton)
            }
        }
    }
}
