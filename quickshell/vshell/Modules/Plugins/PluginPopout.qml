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

            // --- pushed-page contract ---------------------------------------
            // Keyboard focus lives on this container, not on the plugin's
            // content, so a plugin cannot intercept Escape for a page it
            // pushed — which is why a pager's Escape used to close the whole
            // surface instead of going back one level (VGS-88). Content opts in
            // declaratively instead: expose `canPopBack` and `popBack()` on the
            // content root and Escape is routed there first. No key handler in
            // the plugin, and a plugin that knows nothing about this behaves
            // exactly as before.
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

            // All the way back to page 0. `popBack()` is defined as one level,
            // so this loops — bounded, because an implementation whose
            // canPopBack never goes false would otherwise hang the shell here.
            function popContentToRoot() {
                for (let guard = 0; guard < 16; guard++) {
                    if (!popoutContainer.popContentBack())
                        return;
                }
                root.log.warn("plugin popout content did not settle at its root page after 16 pops:", root.layerNamespace);
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    // Back one level before dismissing. Every pager the user
                    // has met pops on Escape; losing the whole surface from a
                    // pushed page is the opposite of what the pattern teaches.
                    if (!popoutContainer.popContentBack())
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
                        return;
                    }
                    // Dismissal — the close button, a click outside, the bar
                    // pill toggling, or anything else that reaches close() —
                    // discards pushed pages rather than popping them. Those
                    // gestures aim at the whole surface, and popping instead
                    // would trap the user, needing a second gesture to leave.
                    // Escape above is the one gesture that conventionally means
                    // "back", so it is the only one routed to the content.
                    // Resetting here is also what keeps "a pushed page is view
                    // state" true no matter which route closed the popout, and
                    // it is owned here so no plugin has to repeat it.
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
