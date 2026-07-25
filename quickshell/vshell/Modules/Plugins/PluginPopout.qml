import QtQuick
import qs.Common
import qs.Widgets

VgsPopout {
    id: root

    layerNamespace: "vshell:plugins:" + layerNamespacePlugin

    property var triggerScreen: null
    property Component pluginContent: null
    property real contentWidth: 400
    property real contentHeight: 0

    popupWidth: contentWidth
    popupHeight: contentHeight
    screen: triggerScreen
    shouldBeVisible: false

    onBackgroundClicked: close()

    content: Component {
        Rectangle {
            id: popoutContainer

            implicitHeight: popoutColumn.implicitHeight + Theme.popoutPadding * 2
            color: "transparent"
            focus: true

            Component.onCompleted: {
                if (root.shouldBeVisible) {
                    forceActiveFocus();
                }
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.close();
                    event.accepted = true;
                }
            }

            Connections {
                target: root
                function onShouldBeVisibleChanged() {
                    if (root.shouldBeVisible) {
                        Qt.callLater(() => {
                            popoutContainer.forceActiveFocus();
                        });
                    }
                }
            }

            Column {
                id: popoutColumn
                width: parent.width - Theme.popoutPadding * 2
                x: Theme.popoutPadding
                y: Theme.popoutPadding
                spacing: Theme.spacingS

                Loader {
                    id: popoutContentLoader
                    width: parent.width
                    sourceComponent: root.pluginContent

                    onLoaded: {
                        if (item && "closePopout" in item) {
                            item.closePopout = function () {
                                root.close();
                            };
                        }
                        if (item && "parentPopout" in item) {
                            item.parentPopout = root;
                        }
                        if (item) {
                            root.contentHeight = Qt.binding(() => item.implicitHeight + Theme.popoutPadding * 2);
                        }
                    }
                }
            }
        }
    }
}
