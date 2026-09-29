import QtQuick
import qs.Commons
import qs.Ui
import "Reply.js" as Reply

// The Settings window: every plugin the manager lists, and one page per
// plugin, drawn from its manager row alone. The panel host builds it as a
// layer surface centred on its monitor; it is `size.window.width` wide, or
// the monitor's width less `size.window.gutter` a side when that is less,
// and `size.window.heightShare` of the monitor's height tall, read from the
// screen its `screens` capability gives. The list page and the plugin page
// sit side by side and slide on `motion.duration.normal`, so a
// `motion.scale` of 0 makes a push or a pop instant; the page not shown is
// hidden once the slide ends, so the keyboard reaches the shown page alone.
// Escape pops a page, then hides the window. Enabling, disabling, a
// setting and a key go through the manager capability; the rows come back
// from the core, so the window shows what the configuration holds.
//
// The payload is a JSON object: `{}` opens the list, `{"plugin":"<id>"}`
// that plugin's page, and an id no plugin has opens the list with a notice
// naming it. Any other key, or a payload that is no object, throws out of
// open(), which refuses the summon.
FocusScope {
    id: root

    property var shell: null
    readonly property var plugins: shell === null ? [] : shell.manager.plugins
    readonly property string title: shell === null ? "" : shell.manifest.name
    readonly property var screen: shell === null ? null : shell.screens.current
    // plugin id -> the last refusal the manager answered for it, shown on
    // its page until a later call for that plugin succeeds.
    property var replies: ({})
    // The page shown: "" for the list, else a plugin id.
    property string page: ""
    // The plugin page drawn, kept while it slides out on a pop.
    property string drawn: ""
    // A line the list shows over the search field, such as a deep link to
    // an id no plugin has.
    property string notice: ""
    // False while a summon places the page, so the window opens on it
    // without a slide.
    property bool sliding: false

    readonly property var current: rowOf(drawn)

    implicitWidth: screen === null ? Theme.size.window.width : Math.floor(Math.min(Theme.size.window.width, screen.width - 2 * Theme.size.window.gutter))
    implicitHeight: screen === null ? Theme.size.panel.maxHeight : Math.floor(Theme.size.window.heightShare * screen.height)
    focus: true

    function rowOf(id) { return plugins.find(p => p.id === id) || null; }

    // Keep one manager reply for plugin `id` and answer it.
    function keep(id, reply) {
        const next = Object.assign({}, replies);
        if (Reply.isOk(reply)) delete next[id];
        else {
            next[id] = reply;
            console.warn("settings: " + id + " " + reply);
        }
        replies = next;
        return reply;
    }

    function open(payloadJson) {
        const payload = JSON.parse(payloadJson === "" ? "{}" : payloadJson);
        if (payload === null || typeof payload !== "object" || Array.isArray(payload))
            throw new Error("payload must be a JSON object, got " + payloadJson);
        for (const key of Object.keys(payload))
            if (key !== "plugin") throw new Error("payload key " + JSON.stringify(key) + " unknown, want plugin");
        if (payload.plugin !== undefined && typeof payload.plugin !== "string")
            throw new Error("payload plugin must be a plugin id, got " + JSON.stringify(payload.plugin));
        sliding = false;
        notice = "";
        if (payload.plugin === undefined) showList();
        else if (rowOf(payload.plugin) === null) {
            showList();
            notice = "No plugin named " + payload.plugin + "; every plugin is listed below.";
        } else openPlugin(payload.plugin);
        Qt.callLater(() => { root.sliding = true; });
    }

    function close() {}

    function showList() {
        page = "";
        list.focusSearch();
    }

    // Open the page of plugin `id`; answers `ok` or `unknown: <id>`.
    function openPlugin(id) {
        if (rowOf(id) === null) return "unknown: " + id;
        notice = "";
        drawn = id;
        page = id;
        detail.focusBack();
        return "ok";
    }

    // Pop the plugin page, or hide the window from the list; answers `ok`
    // or the panel host's reply.
    function back() {
        if (page !== "") {
            showList();
            return "ok";
        }
        return shell.surfaces.hide("panel");
    }

    // Enable or disable plugin `id`, the opposite of its state now; answers
    // the manager's reply.
    function toggle(id) {
        const row = rowOf(id);
        if (row === null) return "unknown: " + id;
        return keep(id, shell.manager.setEnabled(id, !row.enabled));
    }

    // Write one setting of plugin `id` through the manager; answers its
    // reply.
    function writeSetting(id, key, value) {
        return keep(id, shell.manager.setSetting(id, key, value));
    }

    // Set the key of shortcut `shortcut` of plugin `id`: a key string
    // rebinds, null unbinds, undefined resets to the manifest's key;
    // answers the manager's reply.
    function writeKey(id, shortcut, key) {
        return keep(id, shell.manager.setKey(id, shortcut, key));
    }

    Keys.onEscapePressed: back()

    Surface {
        anchors.fill: parent
        level: "raised"
        clip: true

        Item {
            id: pages
            width: 2 * root.width
            height: root.height
            x: root.page === "" ? 0 : -root.width
            Behavior on x {
                enabled: root.sliding
                NumberAnimation { id: slide; duration: Theme.motion.duration.normal; easing.type: Theme.motion.easing.standard }
            }

            // The page not shown is hidden once the slide ends, so Tab,
            // Shift+Tab and the pointer reach the shown page alone; both
            // draw while they slide.
            ListPage {
                id: list
                panel: root
                width: root.width
                height: root.height
                visible: root.page === "" || slide.running
                focus: root.page === ""
            }

            PluginPage {
                id: detail
                panel: root
                row: root.current
                x: root.width
                width: root.width
                height: root.height
                visible: root.page !== "" || slide.running
                focus: root.page !== ""
            }
        }
    }
}
