import QtQuick
import qs.Common
import qs.Widgets

VgsPopout {
    id: root

    layerNamespace: "vshell:plugins:" + layerNamespacePlugin

    property var triggerScreen: null
    property Component pluginContent: null
    property real contentWidth: 400
    // Natural height the plugin content wants, padding included. Bound to the
    // loaded item below; plugins may also set it explicitly for a fixed popout.
    property real contentHeight: 0

    // A layer surface taller than its output gets clamped by the compositor,
    // which silently cuts the bottom off the popout. Cap the surface instead and
    // let the content scroll inside it. Matches ControlCenterPopout's budget.
    readonly property real maxContentHeight: Math.max(200, (triggerScreen?.height ?? 1080) - 100)

    popupWidth: contentWidth
    popupHeight: Math.min(contentHeight, maxContentHeight)
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

            VgsFlickable {
                id: contentFlickable

                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: Math.max(height, popoutColumn.implicitHeight + Theme.popoutPadding * 2)
                interactive: contentHeight > height

                Column {
                    id: popoutColumn
                    width: contentFlickable.width - Theme.popoutPadding * 2
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
}
