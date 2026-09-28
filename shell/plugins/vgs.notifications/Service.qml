import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import qs.Commons
import "Appearance.js" as Appearance
import "NotificationLogic.js" as Logic

// The notification service: every desktop notification the core's server
// receives becomes a glass toast at the top of every screen, and leaves
// into the history when it expires, is dismissed, acted on, closed by its
// sender or let go by a full stack. The Inbox shows what arrived since the
// last Mark read, the History everything kept; while either is open the
// toasts stay and do not expire. Silence keeps notifications off the screen
// and records them in the history, bar a critical one from the bare command
// line. The service owns the rows, their clocks, the live notification
// objects and the store; the stack its layer draws on each screen is only a
// view of them. Everything it registers is the core's to release.
//   shortcut vgs.notifications:inbox     bind it in Hyprland, for example
//                                        `bind = SUPER, N, global, vgs.notifications:inbox`
//   vgsh ipc call vgs.notifications invoke <name> <arg>, names in the README
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)
    property bool registered: false
    property var layerRelease: null

    // The rows every screen's stack draws, newest toast first, then the
    // panel's rows: key, originalId, app, appIcon, summary, body, image,
    // desktopEntry, urgency, expireTimeout, timestamp, origin (live, restored
    // or panel) and leaving (empty, or why the row is going). A live row
    // draws the sender's own images; a restored or panel row draws the copies.
    property alias rows: rowModel
    ListModel { id: rowModel }

    // key -> { notification, links }: the live notification objects, kept
    // out of the model, since a model role holding an object the server
    // destroys dangles. `links` are the [signal, handler] pairs connected to
    // it, disconnected when the row lets go of it.
    property var liveRefs: ({})
    // key -> notification: silenced notifications held until their image
    // copies are made, since the sender deletes its files once told they
    // closed.
    property var silencedRefs: ({})
    // key -> { remaining, since }: the toasts' lifetimes (NotificationLogic).
    property var clocks: ({})
    // key -> how many screens' cards the pointer is on.
    property var hovers: ({})
    // key -> the timer that removes a leaving row once its exit has played.
    property var exits: ({})

    // "", "inbox" or "history".
    property string panelMode: ""
    readonly property bool panelOpen: panelMode !== ""
    readonly property bool panelClosing: panelCloseTimer.running
    readonly property string panelSubtitle: Logic.panelSubtitle(panelMode, shownCount, store.status)
    property int shownCount: 0
    readonly property bool silenced: store.dnd

    // The exit's and the entrance's whole length, from their animations in
    // CardSlot.qml.
    readonly property var durations: look === null ? null : look.motion.duration
    readonly property int exitTime: durations === null ? 0 : Math.max(durations.short3, durations.medium3) + durations.short3
    readonly property int enterTime: durations === null ? 0 : Math.max(durations.short3, durations.medium1) + durations.short2 + Math.max(durations.medium2, durations.medium4, 2 * durations.short4)

    // The layer exists while there is something to draw.
    readonly property bool wanted: look !== null && (rowModel.count > 0 || panelOpen || panelClosing)
    onWantedChanged: syncLayer()

    Store {
        id: store
        onReadyChanged: root.start()
    }

    Component {
        id: stackComponent
        Stack { service: root }
    }

    Component {
        id: exitTimer
        Timer { property string key: "" }
    }

    onShellChanged: start()

    // Registers once, when both the shell and the stored state are here, so
    // no notification arrives before the restored toasts are in place.
    function start() {
        if (shell === null || registered || !store.ready) return;
        if (look === null) {
            console.error("notifications: refused: appearance");
            return;
        }
        registered = true;
        restore();
        shell.shortcut.register("inbox", "Open or close the notification inbox", () => root.togglePanel());
        shell.ipc.handle("inbox", () => root.togglePanel());
        shell.ipc.handle("history", () => { root.openPanel("history"); return "ok"; });
        shell.ipc.handle("close", () => { root.closePanel(); return "ok"; });
        shell.ipc.handle("mark-read", () => { root.markRead(); return "ok"; });
        shell.ipc.handle("clear-history", () => { root.clearHistoryPanel(); return "ok"; });
        shell.ipc.handle("silence", arg => {
            const judged = Logic.silenceArgument(arg, store.dnd);
            if (!judged.ok) return "refused: silence=" + JSON.stringify(arg) + " want=on|off|toggle";
            root.setSilence(judged.dnd);
            return store.dnd ? "on" : "off";
        });
        shell.ipc.handle("dismiss-all", () => {
            const keys = root.rowKeys(r => r.origin !== "panel");
            for (const key of keys) root.leave(key, "dismiss");
            return keys.length === 0 ? "none" : "ok";
        });
        shell.ipc.handle("dismiss-latest", () => root.onLatest(key => root.leave(key, "dismiss")));
        shell.ipc.handle("invoke-latest", () => root.onLatest(key => root.invoke(key)));
        shell.ipc.handle("status", () => root.status());
        shell.notifications.subscribe(n => root.receive(n));
    }

    function syncLayer() {
        if (shell === null || !registered) return;
        if (wanted && layerRelease === null) {
            try {
                layerRelease = shell.layers.show(stackComponent);
            } catch (e) {
                console.error("notifications: layer refused: " + e.message);
            }
        } else if (!wanted && layerRelease !== null) {
            const release = layerRelease;
            layerRelease = null;
            release();
        }
    }

    // ------------------------------------------------------------- rows

    function indexOf(key) {
        for (let i = 0; i < rowModel.count; i++)
            if (rowModel.get(i).key === key) return i;
        return -1;
    }

    function rowKeys(pick) {
        const out = [];
        for (let i = 0; i < rowModel.count; i++) {
            const row = rowModel.get(i);
            if (row.leaving === "" && pick(row)) out.push(row.key);
        }
        return out;
    }

    function onLatest(act) {
        const keys = rowKeys(r => r.origin !== "panel");
        if (keys.length === 0) return "none";
        act(keys[0]);
        return "ok";
    }

    function rowOf(entry, origin) {
        const row = { origin: origin, leaving: "" };
        for (const role of Logic.ENTRY_ROLES) row[role] = entry[role];
        return row;
    }

    function countShown() {
        shownCount = rowKeys(() => true).length;
    }

    // The plain values a notification carries now, or null once the server
    // has torn it down.
    function fieldsOf(n) {
        try {
            return {
                id: n.id, appName: n.appName, appIcon: n.appIcon, summary: n.summary, body: n.body,
                image: n.image, desktopEntry: n.desktopEntry, urgency: n.urgency,
                expireTimeout: n.expireTimeout, transient: n.transient
            };
        } catch (e) {
            return null;
        }
    }

    function taken(key) {
        return indexOf(key) !== -1 || store.hasKey(key) || Logic.hasOwn(silencedRefs, key);
    }

    // ------------------------------------------------------- receiving

    function receive(n) {
        const fields = fieldsOf(n);
        if (fields === null) return;
        const entry = Logic.entryOf(fields, Date.now(), k => root.taken(k));
        if (store.dnd && !Logic.bypassesSilence(fields.appName, fields.urgency)) {
            // Not tracked, so the server discards it at once.
            if (Logic.isEphemeral(fields.appName, fields.transient)) return;
            n.tracked = true;
            silence(n, entry);
            return;
        }
        n.tracked = true;
        // A live toast under this id that the sender let go and sent again
        // is the same notification to it: its row goes without a history
        // entry, since the new one will leave one.
        for (const key of rowKeys(r => r.origin === "live" && r.originalId === entry.originalId)) {
            store.dropLive(key, true);
            unlink(key, "dismiss");
            removeRow(key);
        }
        link(n, entry.key);
        const stored = Logic.persistable(entry, store.imagesDir);
        store.copy(stored.copies, null);
        store.putLive(stored.entry);
        rowModel.insert(0, rowOf(entry, "live"));
        startClock(entry.key, Logic.lifetimeFor(entry.urgency, entry.expireTimeout));
        const onScreen = rowKeys(r => r.origin !== "panel");
        if (onScreen.length > Logic.LIVE_MAX) {
            const rowsOldestLast = onScreen.map(k => ({ key: k, urgency: rowModel.get(root.indexOf(k)).urgency }));
            leave(Logic.evictionKey(rowsOldestLast), "expire");
        }
        countShown();
    }

    // Everything a card draws. A sender updating its notification in place
    // changes these on the object the service already holds, with no second
    // notification signal.
    readonly property var updateSignals: ["summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged", "imageChanged", "urgencyChanged", "expireTimeoutChanged", "desktopEntryChanged"]

    function link(n, key) {
        const links = [];
        const connect = (name, fn) => {
            if (!n[name] || typeof n[name].connect !== "function") {
                console.warn("notifications: notification signal missing: " + name);
                return;
            }
            n[name].connect(fn);
            links.push([name, fn]);
        };
        connect("closed", () => root.senderClosed(key, n));
        for (const name of updateSignals) connect(name, () => root.refresh(key));
        const next = Object.assign({}, liveRefs);
        next[key] = { notification: n, links: links };
        liveRefs = next;
    }

    // Let go of a live notification: disconnect everything, then tell the
    // server how the toast ended, unless the object already closed.
    function unlink(key, how) {
        if (!Logic.hasOwn(liveRefs, key)) return;
        const ref = liveRefs[key];
        const next = Object.assign({}, liveRefs);
        delete next[key];
        liveRefs = next;
        try {
            for (const [name, fn] of ref.links) ref.notification[name].disconnect(fn);
            if (how === "expire") ref.notification.expire();
            else if (how === "dismiss") ref.notification.dismiss();
        } catch (e) {
            // The server tore the object down already; nothing is left to tell.
        }
    }

    // The object closed without the service asking: its sender closed it,
    // or the server let it go. Its toast leaves as a sender's close does.
    function senderClosed(key, n) {
        if (!Logic.hasOwn(liveRefs, key) || liveRefs[key].notification !== n) return;
        unlink(key, "closed");
        leave(key, "closed");
    }

    function refresh(key) {
        const at = indexOf(key);
        if (at === -1 || !Logic.hasOwn(liveRefs, key)) return;
        const fields = fieldsOf(liveRefs[key].notification);
        if (fields === null) return;
        const row = rowModel.get(at);
        const current = {};
        for (const role of Logic.ENTRY_ROLES) current[role] = row[role];
        const updated = Logic.updatedEntry(current, fields);
        if (!Logic.entryChanged(current, updated)) return;
        for (const role of Logic.ENTRY_ROLES) rowModel.setProperty(at, role, updated[role]);
        const stored = Logic.persistable(updated, store.imagesDir);
        store.copy(stored.copies, null);
        store.putLive(stored.entry);
        // New content deserves a whole look: the clock starts over.
        if (row.leaving === "") startClock(key, Logic.lifetimeFor(updated.urgency, updated.expireTimeout));
    }

    // A silenced notification goes straight into the history, held tracked
    // until its image copies exist; an update that lands meanwhile is
    // recorded again under the same key.
    function silence(n, entry) {
        const next = Object.assign({}, silencedRefs);
        next[entry.key] = n;
        silencedRefs = next;
        const stored = Logic.persistable(entry, store.imagesDir);
        store.archive([stored.entry]);
        store.copy(stored.copies, () => {
            const fields = root.fieldsOf(n);
            const updated = fields === null ? null : Logic.updatedEntry(entry, fields);
            if (updated !== null && Logic.entryChanged(entry, updated)) {
                root.silence(n, updated);
                return;
            }
            root.releaseSilenced(entry.key);
        });
    }

    function releaseSilenced(key) {
        if (!Logic.hasOwn(silencedRefs, key)) return;
        const n = silencedRefs[key];
        const next = Object.assign({}, silencedRefs);
        delete next[key];
        silencedRefs = next;
        try {
            n.tracked = false;
        } catch (e) {
            // Already destroyed by the server.
        }
    }

    // --------------------------------------------------------- restore

    // The toasts the previous shell left on screen come back, with no live
    // actions, and the ones whose time ran out meanwhile go into the history.
    function restore() {
        const now = Date.now();
        const plan = Logic.restorePlan(store.live, now);
        for (const entry of plan.expired) store.dropLive(entry.key, false);
        for (const entry of plan.show) {
            store.putLive(entry);
            rowModel.append(rowOf(entry, "restored"));
            if (entry.deadline !== undefined) startClock(entry.key, entry.deadline - now);
        }
        countShown();
    }

    // ---------------------------------------------------------- clocks

    function startClock(key, lifetime) {
        const next = Object.assign({}, clocks);
        if (lifetime > 0) next[key] = { remaining: lifetime + enterTime, since: null };
        else delete next[key];
        clocks = next;
        settle();
    }

    function stopClock(key) {
        if (!Logic.hasOwn(clocks, key)) return;
        const next = Object.assign({}, clocks);
        delete next[key];
        clocks = next;
        settle();
    }

    // Run the clocks of every toast nobody is looking at, while no panel is
    // open, and wake for the first to run out.
    function settle() {
        const now = Date.now();
        clocks = Logic.settleClocks(clocks, key => !root.panelOpen && !(root.hovers[key] > 0), now);
        const first = Logic.nextExpiry(clocks, now);
        if (first === null) expiry.stop();
        else {
            expiry.interval = Math.max(1, first.wait);
            expiry.restart();
        }
    }

    Timer {
        id: expiry
        onTriggered: {
            const now = Date.now();
            for (const key of Object.keys(root.clocks)) {
                const first = Logic.nextExpiry({ [key]: root.clocks[key] }, now);
                if (first !== null && first.wait <= 0) root.leave(key, "expire");
            }
            root.settle();
        }
    }

    onPanelOpenChanged: settle()

    function hover(key, on) {
        const next = Object.assign({}, hovers);
        next[key] = Math.max(0, (next[key] || 0) + (on ? 1 : -1));
        if (next[key] === 0) delete next[key];
        hovers = next;
        settle();
    }

    // ---------------------------------------------------------- leaving

    // Start a row's exit. A toast is off the screen for the store and the
    // server at once, so a rebuild during the exit restores nothing it
    // should not; the row itself goes once its animation has played.
    // `reason` is expire, dismiss, invoke or closed for a toast, fade for a
    // panel row, which goes with the panel's own timer.
    function leave(key, reason) {
        const at = indexOf(key);
        if (at === -1 || rowModel.get(at).leaving !== "") return;
        const origin = rowModel.get(at).origin;
        rowModel.setProperty(at, "leaving", reason);
        stopClock(key);
        countShown();
        if (reason === "fade") return;
        if (origin !== "panel") {
            store.dropLive(key, false);
            unlink(key, reason === "expire" ? "expire" : reason === "closed" ? "closed" : "dismiss");
        }
        const timer = exitTimer.createObject(root, { key: key, interval: Math.max(1, exitTime) });
        timer.triggered.connect(() => root.removeRow(key));
        const next = Object.assign({}, exits);
        next[key] = timer;
        exits = next;
        timer.start();
    }

    // The row off the model, with its exit timer, hover count and clock.
    function removeRow(key) {
        const at = indexOf(key);
        if (at === -1) return;
        if (Logic.hasOwn(exits, key)) {
            const next = Object.assign({}, exits);
            exits[key].destroy();
            delete next[key];
            exits = next;
        }
        rowModel.remove(at);
        if (Logic.hasOwn(hovers, key)) {
            const next = Object.assign({}, hovers);
            delete next[key];
            hovers = next;
        }
        stopClock(key);
        countShown();
    }

    function dismiss(key) {
        leave(key, "dismiss");
    }

    // A click on a card: the sender's default action while it is live, or
    // the sender's window, then the toast leaves.
    function invoke(key) {
        const at = indexOf(key);
        if (at === -1) return;
        const row = rowModel.get(at);
        if (!invokeAction(key, "default")) focusSender(row);
        leave(key, "invoke");
    }

    function invokeAction(key, identifier) {
        if (!Logic.hasOwn(liveRefs, key)) return false;
        try {
            for (const action of liveRefs[key].notification.actions) {
                if (action.identifier !== identifier) continue;
                action.invoke();
                return true;
            }
        } catch (e) {
            console.warn("notifications: action " + identifier + " failed: " + e.message);
        }
        return false;
    }

    function windows() {
        return Hyprland.toplevels.values.map(t => ({
            address: t.address,
            appClass: t.wayland ? t.wayland.appId : (t.lastIpcObject && t.lastIpcObject.class) || ""
        }));
    }

    function focusSender(row) {
        const address = Logic.focusAddress(windows(), row.desktopEntry, row.app);
        if (address === "") return;
        const reply = shell.compositor.focusWindow(address);
        if (reply !== "ok") console.warn("notifications: focus " + reply);
    }

    function actionsFor(key) {
        const at = indexOf(key);
        if (at === -1) return [];
        const row = rowModel.get(at);
        let actions = [];
        if (row.origin === "live" && Logic.hasOwn(liveRefs, key)) {
            try {
                actions = liveRefs[key].notification.actions.map(a => ({ identifier: a.identifier, text: a.text }));
            } catch (e) {
                actions = [];
            }
        }
        return Logic.actionsFor(actions, Logic.focusAddress(windows(), row.desktopEntry, row.app) !== "");
    }

    // A hover action, then the toast leaves.
    function runAction(key, id) {
        const at = indexOf(key);
        if (at === -1) return;
        if (id === "focus") focusSender(rowModel.get(at));
        else if (id.indexOf("action:") === 0) invokeAction(key, id.slice(7));
        leave(key, "dismiss");
    }

    // ------------------------------------------------------------ panel

    function togglePanel() {
        if (panelOpen) closePanel();
        else openPanel("inbox");
        return "ok";
    }

    function openPanel(mode) {
        // Reopened while closing: the faded rows go now, not as blanks.
        if (panelCloseTimer.running) {
            panelCloseTimer.stop();
            removePanelRows();
        }
        panelMode = mode;
        removePanelRows();
        const live = {};
        for (let i = 0; i < rowModel.count; i++) live[rowModel.get(i).key] = true;
        for (const entry of Logic.panelRows(store.history, mode, store.readBefore))
            if (!live[entry.key]) rowModel.append(rowOf(entry, "panel"));
        countShown();
    }

    function closePanel() {
        if (!panelOpen) return;
        panelMode = "";
        fadePanelRows();
    }

    function fadePanelRows() {
        for (const key of rowKeys(r => r.origin === "panel")) leave(key, "fade");
        panelCloseTimer.restart();
    }

    // Panel rows fade in place and then all go in one step, so the stack is
    // laid out once instead of shifting as each row leaves.
    Timer {
        id: panelCloseTimer
        interval: root.look === null ? 1 : root.look.motion.staggerRows * root.look.motion.duration.stagger + root.look.motion.duration.short4 + root.look.motion.settle
        onTriggered: root.removePanelRows()
    }

    function removePanelRows() {
        for (let i = rowModel.count - 1; i >= 0; i--)
            if (rowModel.get(i).origin === "panel") removeRow(rowModel.get(i).key);
    }

    // Mark read: everything so far is read, and the panel closes.
    function markRead() {
        store.setReadBefore(Date.now());
        closePanel();
    }

    // Clear history: the kept notifications go; the panel stays open and its
    // rows fade out.
    function clearHistoryPanel() {
        store.clearHistory();
        if (panelOpen) fadePanelRows();
    }

    function setSilence(on) {
        store.setDnd(on);
    }

    // --------------------------------------------------------- readback

    // The service's state as one JSON line, for `invoke status`.
    function status() {
        return JSON.stringify({
            silence: store.dnd,
            panel: panelMode,
            store: { state: store.status, problem: store.problem },
            onScreen: rowKeys(r => r.origin !== "panel").length,
            history: store.history.length,
            readBefore: store.readBefore
        });
    }

    // Every live object goes back to the server as dismissed, since a
    // notification nobody draws would otherwise stay tracked; its toast stays
    // in the store and comes back restored.
    Component.onDestruction: {
        for (const key of Object.keys(liveRefs)) unlink(key, "dismiss");
        for (const key of Object.keys(silencedRefs)) releaseSilenced(key);
    }
}
