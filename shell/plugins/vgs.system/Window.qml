import QtQuick
import qs.Commons
import qs.Ui
import "Memory.js" as Memory

// The System window: the sidebar of every enabled section, and the chosen
// section beside it. A section is a plugin of kind `pane`; this window
// holds the exclusive `panes` capability, lists the sections from
// `shell.panes.list` and mounts one at a time through `shell.panes.mount`,
// which builds it with that plugin's own shell and destroys the one before
// it (D088). The window host builds the window as a Hyprland window titled
// System. It asks to be `size.panel.sm` wider than `size.window.width`, the
// sidebar's width beside a page as wide as a Settings page, or the
// monitor's width less `size.window.gutter` a side when that is less, and
// `size.window.heightShare` of the monitor's height tall, read from the
// screen its `screens` capability gives.
//
// The detail draws the section's icon and name, and a "Show in bar" switch
// for a section with a bar widget, which places or removes the widget
// through `shell.panes.setPlaced`. The window owns the section's title,
// its inset and its scrolling; the section is a body drawn from x 0, which
// fills the room under the header, or grows to its implicit height and
// scrolls in the page's ScrollArea when it is taller (D050). Moving the
// sidebar's selection mounts nothing; entering a row does, and moves the
// keyboard into the section. Escape in a section returns the keyboard to
// the sidebar's search field; Escape there with no query is left to the
// window host, which closes the window.
//
// The payload is a JSON object: `{}` opens the section shown last, held in
// memory while the shell runs (Memory.js), or the first section;
// `{"pane":"<id>", ...}` opens that section and hands the payload without
// `pane` to its open(). An id no enabled section has opens like `{}` with
// a notice and logs the id. A payload that is no object, a `pane` that is no
// string or another key without `pane` throws out of open(), which refuses
// the summon.
FocusScope {
    id: root

    property var shell: null
    readonly property var panes: shell === null ? [] : shell.panes.list
    readonly property var screen: shell === null ? null : shell.screens.current
    // The id of the mounted section, or "".
    property string paneId: ""
    // The mounted section's name, kept for the notice when its row leaves
    // the list.
    property string paneName: ""
    property var paneDisposer: null
    // A plain sentence over the section, such as a deep link to an id no
    // section has or a refusal; the reply goes to the log. Cleared by the
    // next section shown.
    property string notice: ""
    readonly property var row: rowOf(paneId)
    // The keyboard opens in the section a deep link names, else on the
    // sidebar's search field, its primary input (keyboard.md F3).
    property bool entered: false
    readonly property Item initialFocus: entered ? detail : sidebar.searchField

    implicitWidth: Math.floor(Math.min(Theme.size.panel.sm + Theme.size.window.width, OverlayState.room(screen).width))
    implicitHeight: screen === null ? Theme.size.panel.maxHeight : Math.floor(Theme.size.window.heightShare * screen.height)
    focus: true

    function rowOf(id) { return panes.find(p => p.id === id) || null; }

    // A section that leaves the list while shown, disabled or removed, is
    // unmounted by the core; the window says so and shows none.
    onPanesChanged: {
        if (paneId === "" || rowOf(paneId) !== null) return;
        notice = paneName + " is no longer enabled.";
        paneId = "";
        paneName = "";
        paneDisposer = null;
    }

    function open(payloadJson) {
        const payload = JSON.parse(payloadJson === "" ? "{}" : payloadJson);
        if (payload === null || typeof payload !== "object" || Array.isArray(payload))
            throw new Error("payload must be a JSON object, got " + payloadJson);
        if (payload.pane === undefined) {
            const keys = Object.keys(payload);
            if (keys.length > 0) throw new Error("payload key " + JSON.stringify(keys[0]) + " needs pane");
            showLast();
            return;
        }
        if (typeof payload.pane !== "string")
            throw new Error("payload pane must be a section id, got " + JSON.stringify(payload.pane));
        const rest = Object.assign({}, payload);
        delete rest.pane;
        if (rowOf(payload.pane) === null) {
            showLast();
            notice = "That section is not available.";
            console.warn("system: no section " + payload.pane);
            return;
        }
        show(payload.pane, JSON.stringify(rest));
        entered = paneId === payload.pane;
    }

    function close() {}

    // Show the section shown last, or the first; the keyboard stays on the
    // sidebar.
    function showLast() {
        entered = false;
        const last = rowOf(Memory.last()) !== null ? Memory.last() : panes.length > 0 ? panes[0].id : "";
        if (last !== "") show(last, "{}");
        sidebar.select(last);
    }

    // Mount section `id` with PAYLOADJSON; answers `ok` or the capability's
    // refusal, which the log keeps. The section takes the keyboard as it
    // is built (PaneHost), and keeps it.
    function show(id, payloadJson) {
        const target = rowOf(id);
        const result = shell.panes.mount(id, mountBox, payloadJson);
        if (typeof result !== "function") {
            notice = "Could not open " + (target === null ? id : target.name) + ".";
            console.warn("system: mount " + id + " " + result);
            return result;
        }
        paneDisposer = result;
        paneId = id;
        paneName = target.name;
        notice = "";
        Memory.remember(id);
        sidebar.select(id);
        return "ok";
    }

    // Enter section `id`: mount it unless it is shown, then give it the
    // keyboard. Answers `ok` or the refusal.
    function enterPane(id, reason) {
        if (id !== paneId) return show(id, "{}");
        detail.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason);
        return "ok";
    }

    // Leave the section: the keyboard returns to the sidebar's search
    // field, with the shown section's row selected.
    function leavePane() {
        sidebar.select(paneId);
        sidebar.focusSearch(Qt.ShortcutFocusReason);
    }

    // Show section `id`'s widget in the bar, or remove it, the opposite of
    // its placement now; answers the capability's reply.
    function togglePlaced(id) {
        const target = rowOf(id);
        if (target === null) return "unknown: " + id;
        const reply = shell.panes.setPlaced(id, !target.placed);
        if (reply !== "ok") {
            notice = "Could not change " + target.name + " in the bar.";
            console.warn("system: setPlaced " + id + " " + reply);
        }
        return reply;
    }

    // Open the Settings window, the plugin manager, through the command
    // docs/architecture/settings-window.md names under Payload for another
    // plugin: the `surfaces` capability opens only this plugin's own
    // surfaces.
    function openSettings() {
        const reply = shell.run.detached(["vgsh", "ipc", "call", "shell", "summon", "window", "vgs.settings", "{}"]);
        if (reply !== "ok") {
            notice = "Could not open Settings.";
            console.warn("system: open Settings " + reply);
        }
        return reply;
    }

    Sidebar {
        id: sidebar
        panel: root
        width: Math.min(Theme.size.panel.sm, Math.floor(root.width / 2))
        height: root.height
        focus: true
    }

    Divider {
        id: rule
        vertical: true
        x: sidebar.width
        height: root.height
    }

    FocusScope {
        id: detail
        x: rule.x + rule.width
        width: root.width - x
        height: root.height
        Keys.onEscapePressed: event => {
            root.leavePane();
            event.accepted = true;
        }

        Pane {
            id: page
            anchors.fill: parent
            container: "window"

            header: [
                Column {
                    width: page.contentWidth
                    spacing: Theme.stack.group

                    Label {
                        role: "hint"
                        text: root.notice
                        visible: text !== ""
                        color: Theme.color.warning
                        width: parent.width
                        wrapMode: Text.Wrap
                    }

                    Item {
                        id: heading
                        width: parent.width
                        visible: root.row !== null
                        implicitHeight: Math.max(Theme.size.control.md, title.implicitHeight, placed.implicitHeight)

                        Icon {
                            id: icon
                            name: root.row === null ? "" : root.row.icon
                            size: Theme.icon.size.lg
                            color: Theme.color.text
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Label {
                            id: title
                            role: "h3"
                            text: root.row === null ? "" : root.row.name
                            x: icon.width + Theme.control.gap
                            width: Math.max(0, (placed.visible ? placed.x - Theme.control.gap : parent.width) - x)
                            elide: Text.ElideRight
                            y: topForCapCenter(heading.height)
                        }
                        Switch {
                            id: placed
                            text: "Show in bar"
                            visible: root.row !== null && root.row.hasWidget
                            checked: root.row !== null && root.row.placed
                            x: parent.width - width
                            anchors.verticalCenter: parent.verticalCenter
                            onToggled: {
                                checked = Qt.binding(() => root.row !== null && root.row.placed);
                                root.togglePlaced(root.paneId);
                            }
                        }
                    }
                }
            ]

            EmptyState {
                width: page.contentWidth
                visible: root.panes.length === 0
                iconName: "sliders-horizontal"
                text: "No System section is enabled"
                actionText: "Shell & Plugins"
                onActivated: root.openSettings()
            }

            // The holder's container: the core puts the mounted section in
            // it, filling it, with the section's implicit size as its own
            // (PaneHost). It fills the room under the header, or grows to
            // the section's height, and the page's ScrollArea scrolls it.
            Item {
                id: mountBox
                readonly property Item mounted: children.length > 0 ? children[children.length - 1] : null
                width: page.contentWidth
                height: mounted === null ? 0 : Math.max(page.bodyRoom, mounted.implicitHeight)
            }
        }
    }
}
