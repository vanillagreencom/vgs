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

    // The compositor clamps a layer surface taller than its output and cuts off the bottom. Cap the surface and scroll inside it.
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

            // The container owns Escape. Pushed content exposes canPopBack and popBack() to receive it before dismissal.
            function contentCanPopBack() {
                const item = popoutContentLoader.item;
                return !!(item && ("canPopBack" in item) && item.canPopBack === true && typeof item.popBack === "function");
            }

            // One level. Returns whether there was one to pop, which is what
            // decides whether Escape still closes.
            function popContentBack() {
                if (!popoutContainer.contentCanPopBack())
                    return false;
                popoutContentLoader.item.popBack();
                return true;
            }

            // Reset pushed pages. Bound the loop so a plugin that never clears canPopBack cannot hang the shell.
            function popContentToRoot() {
                for (let guard = 0; guard < 16; guard++) {
                    if (!popoutContainer.popContentBack())
                        return;
                }
                // Check after the final iteration so content that reaches the root at the bound does not produce a warning.
                if (!popoutContainer.contentCanPopBack())
                    return;
                root.log.warn("plugin popout content did not settle at its root page after 16 pops:", root.layerNamespace);
            }

            Keys.onPressed: event => {
                if (event.key !== Qt.Key_Escape)
                    return;
                event.accepted = true;
                // Accept Escape repeats without acting: holding the key must not pop a page and then dismiss the surface.
                if (event.isAutoRepeat)
                    return;

                if (!popoutContainer.popContentBack())
                    root.close();
            }

            // Reset after popoutClosed so pages do not visibly return to the root during the close animation.
            property bool resetPending: false

            Connections {
                target: root

                function onShouldBeVisibleChanged() {
                    if (root.shouldBeVisible) {
                        Qt.callLater(() => {
                            popoutContainer.forceActiveFocus();
                        });
                        // Reopening cancels the close timer and its popoutClosed signal. Apply the pending reset here.
                        if (popoutContainer.resetPending) {
                            popoutContainer.resetPending = false;
                            popoutContainer.popContentToRoot();
                        }
                        return;
                    }
                    // Dismissal discards pushed pages. Only Escape returns one level within the content.
                    popoutContainer.resetPending = true;
                }

                function onPopoutClosed() {
                    if (!popoutContainer.resetPending)
                        return;
                    popoutContainer.resetPending = false;
                    popoutContainer.popContentToRoot();
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
