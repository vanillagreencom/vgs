import QtQuick
import qs.Commons
import qs.Ui
import "Reply.js" as Reply

// The Settings window: every plugin the manager lists, and one page per
// plugin, drawn from its manager row alone. The window host builds it as a
// Hyprland window titled Settings, which Hyprland floats, centres, frames
// and focuses like any other window. It asks to be `size.window.width`
// wide, or the monitor's width less `size.window.gutter` a side when that
// is less, and `size.window.heightShare` of the monitor's height tall, read
// from the screen its `screens` capability gives; the pages fill whatever
// size the window has after that. The list page and the plugin page
// sit side by side and slide on `motion.duration.normal`, so a
// `motion.scale` of 0 makes a push or a pop instant; the page not shown is
// hidden once the slide ends, so the keyboard reaches the shown page alone.
// Escape pops a page; on the list it is left to the window host, which
// closes the window. Enabling, disabling, a
// setting and a key go through the manager capability; the rows come back
// from the core, so the window shows what the configuration holds. Adding,
// updating and removing a plugin open the manager's core TUIs, a floating
// terminal where each question stays a question, and Install shows the
// core's requirement notice; the window stays open behind them, and its
// rows change once the command there ends.
//
// The payload is a JSON object: `{}` opens the list, `{"plugin":"<id>"}`
// that plugin's page, and an id no plugin has opens the list with a notice
// naming it. Any other key, or a payload that is no object, throws out of
// open(), which refuses the summon. A plugin that leaves the manager's rows
// while its page is shown, as a removal's rescan does, returns the window
// to the list with a notice naming it.
FocusScope {
    id: root

    property var shell: null
    readonly property var plugins: shell === null ? [] : shell.manager.plugins
    readonly property string title: shell === null ? "" : shell.manifest.name
    readonly property var screen: shell === null ? null : shell.screens.current
    // plugin id -> the last refusal the manager answered for it, shown on
    // its page until a later call for that plugin succeeds.
    property var replies: ({})
    // The last refusal or failure of a status step (D058), by
    // `<id>/<key>` for an action and `<id>/<key>/<account>` for a secret,
    // shown under that line until a later step there succeeds.
    property var stepReplies: ({})
    // The `<id>/<key>/<account>` of the secret write running, or "".
    property string writing: ""
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

    implicitWidth: Math.floor(Math.min(Theme.size.window.width, OverlayState.room(screen).width))
    implicitHeight: screen === null ? Theme.size.panel.maxHeight : Math.floor(Theme.size.window.heightShare * screen.height)
    focus: true

    function rowOf(id) { return plugins.find(p => p.id === id) || null; }

    onPluginsChanged: {
        if (page === "" || rowOf(page) !== null) return;
        const gone = page;
        showList();
        notice = gone + " is no longer listed.";
    }

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

    // Pop the plugin page to the list; answers `ok`.
    function back() {
        showList();
        return "ok";
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

    // Open the update of installed plugin `id` or its removal in a floating
    // terminal, or the requirement notice for its missing commands, through
    // the manager; each answers the manager's reply. The terminal is a newer
    // window, which Hyprland focuses and stacks over this one, and the
    // notice sits on a layer over every window, so this window stays open
    // behind them and its rows show the command's result once it ends.
    function updatePlugin(id) { return keep(id, shell.manager.update(id)); }
    function removePlugin(id) { return keep(id, shell.manager.remove(id)); }
    function installRequirements(id) { return keep(id, shell.manager.installRequirements(id)); }

    // Keep one step reply under STEP, a key of `stepReplies`, and answer it.
    function keepStep(step, reply) {
        const next = Object.assign({}, stepReplies);
        if (Reply.isOk(reply)) delete next[step];
        else {
            next[step] = reply;
            console.warn("settings: " + step + " " + reply);
        }
        stepReplies = next;
        return reply;
    }

    // Run the action of plugin `id`'s status entry `key` through the
    // manager: its floating TUI, which Hyprland focuses over this window,
    // or the requirement notice; answers the manager's reply (D058).
    function act(id, key) {
        return keepStep(id + "/" + key, shell.manager.act(id, key));
    }

    // Store what the user typed as plugin `id`'s secret `account`, listed
    // in its status entry `key`, or clear it, through the manager, which
    // writes libsecret; each answers the manager's reply, and the write's
    // end, a failure included, reads under the line. The secret goes to the
    // manager alone: no reply, log line or property here holds it.
    function storeSecret(id, key, account, secret) {
        return secretStep(id + "/" + key + "/" + account, done => shell.manager.storeSecret(id, key, account, secret, done));
    }
    function clearSecret(id, key, account) {
        return secretStep(id + "/" + key + "/" + account, done => shell.manager.clearSecret(id, key, account, done));
    }

    function secretStep(step, call) {
        const reply = keepStep(step, call(result => {
            if (root.writing === step) root.writing = "";
            root.keepStep(step, result.ok ? "ok" : "refused: secret write failed " + result.reason);
        }));
        if (Reply.isOk(reply)) writing = step;
        return reply;
    }

    // Open the add of a plugin from a git URL in a floating terminal through
    // the manager; a refusal stays over the list until a later add opens.
    function addPlugin() {
        const reply = shell.manager.add();
        notice = Reply.isOk(reply) ? "" : reply;
        if (notice !== "") console.warn("settings: add " + reply);
        return reply;
    }

    // Set the key of shortcut `shortcut` of plugin `id`: a key string
    // rebinds, null unbinds, undefined resets to the manifest's key;
    // answers the manager's reply.
    function writeKey(id, shortcut, key) {
        return keep(id, shell.manager.setKey(id, shortcut, key));
    }

    // Escape on a plugin page pops it; on the list it goes on to the window
    // host, which closes the window.
    Keys.onEscapePressed: event => {
        if (page === "") event.accepted = false;
        else back();
    }

    Item {
        anchors.fill: parent
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
