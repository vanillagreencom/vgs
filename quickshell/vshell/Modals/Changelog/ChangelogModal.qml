import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

FloatingWindow {
    id: root

    property bool disablePopupTransparency: true
    readonly property int modalWidth: 680
    readonly property int modalHeight: screen ? Math.min(720, screen.height - 80) : 720

    signal changelogDismissed

    function show() {
        dismissed = false;
        visible = true;
    }

    objectName: "changelogModal"
    title: I18n.tr("What's New")
    minimumSize: Qt.size(modalWidth, modalHeight)
    maximumSize: Qt.size(modalWidth, modalHeight)
    color: Theme.surfaceContainer
    visible: false

    // Every close path writes the marker. Closing through the compositor
    // (Alt+F4, the window menu) only hid the window, so the notes came back on
    // the next launch as though they had never been read.
    onClosed: dismiss()

    FocusScope {
        id: contentFocusScope
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: event => {
            root.dismiss();
            event.accepted = true;
        }

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Return:
            case Qt.Key_Enter:
                root.dismiss();
                event.accepted = true;
                break;
            }
        }

        MouseArea {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: headerRow.height + Theme.spacingM
            onPressed: windowControls.tryStartMove()
            onDoubleClicked: windowControls.tryToggleMaximize()
        }

        Item {
            id: headerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            height: Math.round(Theme.fontSizeMedium * 2.85)

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsActionButton {
                    visible: windowControls.canMaximize
                    iconName: root.maximized ? "fullscreen_exit" : "fullscreen"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: windowControls.tryToggleMaximize()
                }

                VgsActionButton {
                    iconName: "close"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: root.dismiss()

                    VgsTooltip {
                        text: I18n.tr("Close")
                    }
                }
            }
        }

        VgsFlickable {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: headerRow.bottom
            anchors.bottom: footerRow.top
            anchors.topMargin: Theme.spacingS
            clip: true
            contentHeight: mainColumn.height + Theme.spacingL * 2
            contentWidth: width

            ChangelogContent {
                id: mainColumn
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(600, parent.width - Theme.spacingXL * 2)
            }
        }

        Rectangle {
            id: footerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.round(Theme.fontSizeMedium * 4.5)
            color: Theme.surfaceContainerHigh

            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: 1
                color: Theme.outlineMedium
                opacity: 0.5
            }

            Row {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                VgsButton {
                    text: I18n.tr("Read Full Release Notes")
                    iconName: "open_in_new"
                    backgroundColor: Theme.surfaceContainerHighest
                    textColor: Theme.surfaceText
                    onClicked: Qt.openUrlExternally("https://github.com/vanillagreencom/vgs/releases")
                }

                VgsButton {
                    text: I18n.tr("Got It")
                    iconName: "check"
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: root.dismiss()
                }
            }
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: root
    }

    property bool dismissed: false

    function dismiss() {
        if (dismissed)
            return;
        dismissed = true;
        ChangelogService.dismissChangelog();
        changelogDismissed();
        visible = false;
    }
}
