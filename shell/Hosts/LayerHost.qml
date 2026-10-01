import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core

// The passive layer surfaces: one per screen for every registration in
// Layers, each drawing one copy of the plugin's component. The surface
// covers the part of its screen other layers do not reserve and sits on the
// overlay layer and never takes keyboard focus, so it cannot steal input
// from the focused application. Pointer input reaches it only where its
// content says: the whole surface while the content's `inputAll` is true,
// otherwise the union of its
// `inputItems`, and nowhere without any. The
// core assigns the content its `screen` after creation; a content without
// that property is not built, logged, and maps no surface. A screen that
// goes takes its surfaces with it.
Scope {
    id: host

    Component.onCompleted: Plugins.registerHost("layer", host)

    // Every screen keeps its scope, surfaces or none, so a registration that
    // ends as another begins never tears a scope down while its inner
    // Variants still answers the new one.
    Variants {
        model: Quickshell.screens

        Scope {
            id: onScreen

            required property var modelData

            Variants {
                model: Layers.serials

                OverlaySurface {
                    id: win

                    required property int modelData
                    // Read once, not bound: the entry leaves Layers before its
                    // surface goes.
                    property var entry: null
                    property Item content: null
                    // The screen name the content was built on, kept while the
                    // screen itself reads null during teardown.
                    property string builtOn: ""
                    placement: "center"
                    inset: 0
                    inputAll: content !== null && content.inputAll === true
                    inputItems: content !== null && content.inputItems !== undefined ? content.inputItems : []
                    screen: onScreen.modelData
                    // Mapped only once its content is built, so a content the
                    // host refused leaves no surface.
                    visible: content !== null
                    WlrLayershell.namespace: "vgs:layer"
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

                    Component.onCompleted: build()
                    Component.onDestruction: drop()

                    Connections {
                        target: Layers
                        function onReleased(serial) { if (serial === win.modelData) win.drop(); }
                    }

                    function build() {
                        entry = Layers.entryOf(modelData);
                        if (entry === null) {
                            console.error("layers: no registration for serial " + modelData + ": the host's model ran ahead of Layers.entries");
                            return;
                        }
                        const name = screen ? screen.name : "";
                        const item = entry.component.createObject(win.contentItem);
                        if (item === null) {
                            console.error("layers: " + entry.pluginId + " content not built on " + name + ": createObject answered null");
                            return;
                        }
                        try {
                            item.screen = screen;
                            item.anchors.fill = win.contentItem;
                        } catch (e) {
                            console.error("layers: " + entry.pluginId + " content not built on " + name + ": " + e.message);
                            item.destroy();
                            return;
                        }
                        content = item;
                        builtOn = name;
                        entry.screens[name] = item;
                    }

                    function drop() {
                        if (content === null || entry === null) return;
                        const item = content;
                        content = null;
                        if (entry.screens[builtOn] === item) delete entry.screens[builtOn];
                        builtOn = "";
                        item.destroy();
                    }
                }
            }
        }
    }
}
