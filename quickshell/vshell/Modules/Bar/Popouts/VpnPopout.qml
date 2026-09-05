import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets

VgsPopout {
    id: root

    layerNamespace: "vshell:vpn"

    Ref {
        service: NetworkBackendService
    }

    property bool wasVisible: false
    property var triggerScreen: null

    popupWidth: 380
    popupHeight: Math.min((screen ? screen.height : Screen.height) - 100, contentLoader.item ? contentLoader.item.implicitHeight : 320)
    triggerWidth: 70
    screen: triggerScreen
    shouldBeVisible: false

    onShouldBeVisibleChanged: {
        if (shouldBeVisible && !wasVisible) {
            NetworkBackendService.getState();
        }
        wasVisible = shouldBeVisible;
    }

    onBackgroundClicked: close()

    content: Component {
        Rectangle {
            id: content

            implicitHeight: contentColumn.height + Theme.popoutPadding * 2
            color: "transparent"
            focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.close();
                    event.accepted = true;
                }
            }

            Column {
                id: contentColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.popoutPadding
                spacing: Theme.spacingM

                RowLayout {
                    width: parent.width
                    height: 32
                    spacing: Theme.spacingS

                    StyledText {
                        text: I18n.tr("VPN Connections")
                        font.pixelSize: Theme.fontSizeXLarge
                        color: Theme.surfaceText
                        font.weight: Font.Bold
                        Layout.fillWidth: true
                    }

                    VgsActionButton {
                        iconName: "close"
                        iconSize: Theme.iconSize - 4
                        iconColor: Theme.surfaceText
                        onClicked: root.close()
                    }
                }

                // The shared gap under a popout title. A spacer rather than a
                // margin because this is a plain Column, and it carries only
                // the difference this column's spacing does not already give.
                Item {
                    width: 1
                    height: Math.max(0, Theme.popoutHeaderGap - Theme.spacingM)
                }

                VpnDetailContent {
                    width: parent.width
                    listHeight: 200
                    parentPopout: root
                }
            }
        }
    }
}
