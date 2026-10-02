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
// toasts stay and do not expire. Opening a toast or an inbox row, or any
// action of the sender's, delivers that action while the service still
// holds the notification and brings the sender's window into view
// (NotificationLogic.choicePlan). Silence keeps notifications off the
// screen and records them in the history, bar a critical one from the bare
// command line. The service owns the rows, their clocks, the notification
// objects it holds and the store; the stack its layer draws on each screen
// is only a view of them. Everything it registers is the core's to release.
//   shortcut vgs.notifications:inbox     SUPER+N from the manifest's
//                                        `hyprland` binds (README)
//   vgsh ipc call vgs.notifications invoke <name> <arg>, names in the README
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // A normal toast's lifetime floor, from the `duration` setting in
    // seconds; the manifest's default and the schema's bounds make it a
    // number from 2 to 30.
    readonly property int normalLifetime: shell === null ? 0 : shell.settings.duration * 1000
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

    // key -> { notification, links }: the notification objects the service
    // holds, kept out of the model, since a model role holding an object the
    // server destroys dangles: each live toast's, and after it leaves the one
    // its history entry can still open (NotificationLogic.heldAfterLeave),
    // until that entry goes, the user dismisses it or its sender closes it.
    // At most one per stored entry, so the history's limit bounds them.
    // `links` are the [signal, handler] pairs connected to it, disconnected
    // when the service lets go of it.
    property var held: ({})
    // key -> notification: silenced notifications waiting for their image
    // copies, since the sender deletes its files once told they closed; then
    // held as above.
    property var silencedRefs: ({})
    // key -> { remaining, since }: the toasts' lifetimes (NotificationLogic).
    property var clocks: ({})
    // key -> how many screens' cards the pointer is on.
    property var hovers: ({})
    // key -> the timer that removes a leaving row once its exit has played.
    property var exits: ({})
    // The messages a rule read lately (NotificationLogic.messageOf), to find
    // a second copy of one from the sender's other client; and how many
    // such copies went, by the client whose copy stayed.
    property var recentMessages: []
    property var duplicates: ({ keptDesktop: 0, keptBrowser: 0 })

    // "", "inbox" or "history".
    property string panelMode: ""
    readonly property bool panelOpen: panelMode !== ""
    property bool panelFocused: false
    readonly property string panelSubtitle: Logic.panelSubtitle(panelMode, shownCount, store.status)
    property int shownCount: 0
    readonly property bool silenced: store.dnd
    property int panelRevision: 0

    // The exit's and the entrance's whole length, from their animations in
    // CardSlot.qml.
    readonly property var durations: look === null ? null : look.motion.duration
    readonly property int exitTime: durations === null ? 0 : Math.max(durations.short3, durations.medium3) + durations.short3
    readonly property int enterTime: durations === null ? 0 : Math.max(durations.short3, durations.medium1) + durations.short2 + Math.max(durations.medium2, durations.medium4, 2 * durations.short4)

    // The layer exists while there is something to draw.
    readonly property bool wanted: look !== null && rowModel.count > 0 && !panelOpen
    onWantedChanged: syncLayer()

    Store {
        id: store
        onReadyChanged: root.start()
    }

    // One per NotificationLogic rule that keeps a workspace list.
    Variants {
        id: workspaceSources
        model: Logic.workspaceRuleIds()
        WorkspaceIcons {}
    }

    // The workspace list of the Slack rule, which the photos read too.
    readonly property var slackSource: {
        for (const source of workspaceSources.instances)
            if (source.ruleId === "slack") return source;
        return null;
    }

    SlackPhotos {
        id: slackPhotos
        workspaces: root.slackSource === null ? [] : root.slackSource.known
        listed: root.slackSource !== null && root.slackSource.listRead
        emojiEnabled: root.shell !== null && root.shell.settings.customEmoji === true
        photosEnabled: root.shell !== null && root.shell.settings.slackPhotos === true
        secretRevision: root.shell === null ? 0 : root.shell.secrets.revision
        onTokenStatesChanged: root.publishTokens()
        onTeamsChanged: root.publishTokens()
        onWorkspacesChanged: root.publishTokens()
    }

    // The Slack token rows of the plugin's status, a `presenceList`: each
    // listed workspace's token state, its libsecret account, which the
    // Settings page's Connect and Disconnect write through the core, and the
    // command that stores it, as the probe last found them
    // (NotificationLogic.slackTokenRows). No token enters status. While the
    // probe has not answered for the list as it now stands, and while the
    // Slack photos extra is off, the rows wait for its next answer; the
    // core shows no row of an extra that is off.
    function publishTokens() {
        if (shell === null || slackPhotos.tokenStates === null) return;
        const rows = Logic.slackTokenRows(slackPhotos.workspaces, slackPhotos.tokenStates, slackPhotos.teams);
        if (!rows.ok || JSON.stringify(shell.status.values.slackTokens) === JSON.stringify(rows.items)) return;
        const reply = shell.status.set("slackTokens", rows.items);
        if (reply !== "ok") console.error("notifications: " + reply);
    }

    function bumpPanel() {
        panelRevision += 1;
        if (shell !== null) {
            const reply = shell.status.set("panelRevision", panelRevision);
            if (reply !== "ok") console.error("notifications: panelRevision " + reply);
        }
    }

    // The workspace a card of `enrichment` belongs to, the one its summary
    // names or, for Slack, the one its list and photos resolve.
    function workspaceOf(enrichment) {
        return Logic.slackWorkspaceFor(enrichment, slackPhotos.workspaces, slackPhotos.teams);
    }

    // The icon file URL of a workspace a rule's sender named, or "".
    function workspaceIcon(ruleId, workspace) {
        if (workspace === "") return "";
        for (const source of workspaceSources.instances) {
            if (source.ruleId !== ruleId) continue;
            const icon = source.iconFor(workspace);
            if (icon !== "") return icon;
        }
        if (ruleId === "slack") return slackPhotos.workspaceIcon(workspace);
        return "";
    }

    function faceImages(enrichment, carriedImage, workspace) {
        return slackPhotos.faceImages(enrichment, carriedImage, workspace);
    }

    // The custom emoji lookup of a card in `workspace`, or null
    // (NotificationLogic.slackEmojiFor). It reads what the last helper run
    // left in memory and nothing else.
    function emojiFor(enrichment, workspace) {
        return Logic.slackEmojiFor(slackPhotos.emoji, enrichment, slackPhotos.workspaces, slackPhotos.teams, workspace);
    }

    // A notification arrived or changed: a workspace its rule does not yet
    // hold an icon for sends that rule's list to be read again.
    function wantWorkspace(entry) {
        const enrichment = Logic.enrich(entry.app, entry.desktopEntry, entry.appIcon, entry.summary, entry.body);
        if (enrichment === null || enrichment.workspace === "") return;
        for (const source of workspaceSources.instances)
            if (source.ruleId === enrichment.rule) source.want(enrichment.workspace);
    }

    Component {
        id: stackComponent
        Stack { service: root }
    }

    Component {
        id: exitTimer
        Timer { property string key: "" }
    }

    onShellChanged: {
        start();
        publishTokens();
    }

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
        shell.status.set("panelRevision", panelRevision);
        shell.shortcut.register("inbox", "Open or close the notification inbox", () => root.togglePanel());
        shell.ipc.handle("inbox", () => root.togglePanel());
        shell.ipc.handle("panel", () => root.showPanel("inbox"));
        shell.ipc.handle("history", () => root.showPanel("history"));
        shell.ipc.handle("close", () => { root.closePanel(); return "ok"; });
        shell.ipc.handle("mark-read", () => { root.markRead(); return "ok"; });
        shell.ipc.handle("clear-history", () => { root.clearHistoryPanel(); return "ok"; });
        shell.ipc.handle("panel-opened", mode => { root.panelOpened(mode); return "ok"; });
        shell.ipc.handle("panel-closed", () => { root.panelClosed(); return "ok"; });
        shell.ipc.handle("panel-focused", arg => { root.panelFocused = arg === "on"; root.settle(); return "ok"; });
        shell.ipc.handle("panel-state", () => JSON.stringify(root.panelSnapshot()));
        shell.ipc.handle("hover", arg => root.hoverFromPanel(arg));
        shell.ipc.handle("choose", arg => root.chooseFromPanel(arg));
        shell.ipc.handle("silence", arg => {
            const judged = Logic.silenceArgument(arg, store.dnd);
            if (!judged.ok) return "refused: silence=" + JSON.stringify(arg) + " want=on|off|toggle";
            root.setSilence(judged.dnd);
            return store.dnd ? "on" : "off";
        });
        shell.ipc.handle("dismiss-all", () => {
            const keys = root.rowKeys(() => true);
            for (const key of keys) root.leave(key, "dismiss");
            return keys.length === 0 ? "none" : "ok";
        });
        shell.ipc.handle("dismiss-latest", () => root.onLatest(key => root.leave(key, "dismiss")));
        shell.ipc.handle("invoke-latest", () => root.onLatest(key => root.choose(key, "open")));
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
        const keys = rowKeys(() => true);
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
                expireTimeout: n.expireTimeout, transient: n.transient, hints: n.hints
            };
        } catch (e) {
            return null;
        }
    }

    function taken(key) {
        return indexOf(key) !== -1 || store.hasKey(key) || Logic.hasOwn(silencedRefs, key);
    }

    // ------------------------------------------------------- receiving

    // A notification arrives: a toast, or under Silence a history entry.
    // Answers whether the service keeps it; one it does not keep is not
    // tracked, so the server discards a new one at once.
    function receive(n) {
        const fields = fieldsOf(n);
        if (fields === null) return false;
        const refusedHints = Logic.readHints(fields.hints).refused;
        if (refusedHints.length > 0) console.warn("notifications: hints refused: app=" + JSON.stringify(fields.appName) + " names=" + refusedHints.join(","));
        const entry = Logic.entryOf(fields, Date.now(), k => root.taken(k));
        // A second copy of a message that stays out is not kept.
        if (!keepCopy(entry)) return false;
        wantWorkspace(entry);
        if (store.dnd && !Logic.bypassesSilence(fields.appName, fields.urgency)) {
            if (Logic.isEphemeral(fields.appName, fields.transient)) return false;
            n.tracked = true;
            silence(n, entry);
            return true;
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
        bumpPanel();
        startClock(entry.key, Logic.lifetimeFor(entry.urgency, entry.expireTimeout, root.normalLifetime));
        const onScreen = rowKeys(() => true);
        if (onScreen.length > Logic.LIVE_MAX) {
            const rowsOldestLast = onScreen.map(k => ({ key: k, urgency: rowModel.get(root.indexOf(k)).urgency }));
            leave(Logic.evictionKey(rowsOldestLast), "expire");
        }
        countShown();
        return true;
    }

    // Whether a new notification shows: false for a second copy of a
    // message another client already delivered, whose first copy stays;
    // true otherwise, after the first copy's toast, while it is still on
    // screen, leaves with no history entry when this copy is the one to
    // keep. A matched pair is settled and matches no later message
    // (NotificationLogic.receiveMessage). Logs which client's copy stayed,
    // with no content.
    function keepCopy(entry) {
        const message = Logic.messageOf(entry);
        if (message === null) return true;
        const read = Logic.receiveMessage(recentMessages, message, key => {
            const at = root.indexOf(key);
            return at !== -1 && rowModel.get(at).origin === "live" && rowModel.get(at).leaving === "";
        });
        recentMessages = read.recent;
        if (read.prior === null) return true;
        const kept = read.kept === "message" ? message : read.prior;
        const dropped = kept === message ? read.prior : message;
        console.info("notifications: " + message.rule + " duplicate: kept=" + kept.source + " dropped=" + dropped.source);
        const next = Object.assign({}, duplicates);
        if (kept.source === "desktop") next.keptDesktop += 1;
        else next.keptBrowser += 1;
        duplicates = next;
        if (kept !== message) return false;
        store.dropLive(read.prior.key, true);
        unlink(read.prior.key, "dismiss");
        removeRow(read.prior.key);
        return true;
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
        for (const name of updateSignals) connect(name, () => root.noteChange(key));
        const next = Object.assign({}, held);
        next[key] = { notification: n, links: links };
        held = next;
    }

    // key -> true for a held notification its sender changed in this turn
    // of the event loop. The server sets an update's properties together
    // and each signals on its own, so the service takes the update once,
    // after the last signal: one replacement is one update, and it never
    // reads a notification half updated.
    property var changed: ({})

    function noteChange(key) {
        if (Logic.hasOwn(changed, key)) return;
        const next = Object.assign({}, changed);
        next[key] = true;
        changed = next;
        Qt.callLater(root.refreshChanged);
    }

    function refreshChanged() {
        const keys = Object.keys(changed);
        changed = ({});
        for (const key of keys) refresh(key);
    }

    // Let go of a held notification: disconnect everything, then close it
    // on the server as `how` says, expire or dismiss; drop tells the server
    // nothing, for an object that closed already or is handed on.
    function unlink(key, how) {
        if (!Logic.hasOwn(held, key)) return;
        const ref = held[key];
        const next = Object.assign({}, held);
        delete next[key];
        held = next;
        try {
            for (const [name, fn] of ref.links) ref.notification[name].disconnect(fn);
            if (how === "expire") ref.notification.expire();
            else if (how === "dismiss") ref.notification.dismiss();
        } catch (e) {
            // The server tore the object down already; nothing is left to tell.
        }
    }

    // Whether the row of `key` is a toast on screen that is not leaving.
    function onScreen(key) {
        const at = indexOf(key);
        return at !== -1 && rowModel.get(at).origin === "live" && rowModel.get(at).leaving === "";
    }

    // The object closed without the service asking: its sender closed it,
    // or the server let it go, as it does after an action. Its toast leaves
    // as a sender's close does; its history entry stays and opens no more
    // than the sender's window.
    function senderClosed(key, n) {
        if (!Logic.hasOwn(held, key) || held[key].notification !== n) return;
        unlink(key, "drop");
        if (onScreen(key)) leave(key, "closed");
    }

    // A held notification its sender updated in place: a toast on screen
    // draws the change; one held for the history arrives again, as a new
    // notification under a new key, since the sender sent something new,
    // and the history keeps what was shown.
    function refresh(key) {
        if (!Logic.hasOwn(held, key)) return;
        if (!onScreen(key)) {
            const n = held[key].notification;
            unlink(key, "drop");
            if (!receive(n)) {
                try {
                    n.dismiss();
                } catch (e) {
                    // Already destroyed by the server.
                }
            }
            return;
        }
        const at = indexOf(key);
        const fields = fieldsOf(held[key].notification);
        if (fields === null) return;
        const row = rowModel.get(at);
        const current = {};
        for (const role of Logic.ENTRY_ROLES) current[role] = row[role];
        const updated = Logic.updatedEntry(current, fields);
        if (!Logic.entryChanged(current, updated)) return;
        wantWorkspace(updated);
        for (const role of Logic.ENTRY_ROLES) rowModel.setProperty(at, role, updated[role]);
        bumpPanel();
        const stored = Logic.persistable(updated, store.imagesDir);
        store.copy(stored.copies, null);
        store.putLive(stored.entry);
        // New content deserves a whole look: the clock starts over.
        startClock(key, Logic.lifetimeFor(updated.urgency, updated.expireTimeout, root.normalLifetime));
    }

    // A silenced notification goes straight into the history, held once
    // its image copies exist, as a toast that expired is; an update that
    // lands before then is recorded again under the same key.
    function silence(n, entry) {
        const next = Object.assign({}, silencedRefs);
        next[entry.key] = n;
        silencedRefs = next;
        const stored = Logic.persistable(entry, store.imagesDir);
        store.archive([stored.entry]);
        // An open panel shows it once its copies exist, so the row never
        // points at an image still being copied.
        store.copy(stored.copies, () => {
            const fields = root.fieldsOf(n);
            const updated = fields === null ? null : Logic.updatedEntry(entry, fields);
            if (updated !== null && Logic.entryChanged(entry, updated)) {
                root.silence(n, updated);
                return;
            }
            root.bumpPanel();
            root.holdSilenced(entry.key);
        });
    }

    // Held as a toast that expired is, unless its entry went meanwhile.
    function holdSilenced(key) {
        if (!Logic.hasOwn(silencedRefs, key)) return;
        const n = silencedRefs[key];
        const fields = fieldsOf(n);
        if (fields === null || !store.hasKey(key) || Logic.heldAfterLeave("expire", fields.transient) !== "keep") {
            releaseSilenced(key);
            return;
        }
        const next = Object.assign({}, silencedRefs);
        delete next[key];
        silencedRefs = next;
        link(n, key);
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
        const plan = Logic.restorePlan(store.live, now, root.normalLifetime);
        for (const entry of plan.expired) store.dropLive(entry.key, false);
        for (const entry of plan.show) {
            store.putLive(entry);
            rowModel.append(rowOf(entry, "restored"));
            bumpPanel();
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

    // Run the clocks of every toast nobody is looking at, while the panel
    // does not hold the keyboard, and wake for the first to run out.
    function settle() {
        const now = Date.now();
        clocks = Logic.settleClocks(clocks, key => !(root.panelOpen && root.panelFocused) && !(root.hovers[key] > 0), now);
        // The store keeps each toast's clock, so a restart judges it as it
        // stood.
        for (const key of Object.keys(clocks)) store.setClock(key, Logic.clockFields(clocks[key]));
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

    // Start a row's exit. A toast is off the screen for the store at once,
    // so a rebuild during the exit restores nothing it should not, and its
    // notification is held for the history or closed as
    // NotificationLogic.heldAfterLeave says; the row itself goes once its
    // animation has played. `reason` is expire, dismiss, invoke or closed.
    function leave(key, reason) {
        const at = indexOf(key);
        if (at === -1 || rowModel.get(at).leaving !== "") return;
        rowModel.setProperty(at, "leaving", reason);
        stopClock(key);
        countShown();
        store.dropLive(key, false);
        if (Logic.hasOwn(held, key)) {
            const fields = fieldsOf(held[key].notification);
            const fate = fields === null ? "drop" : Logic.heldAfterLeave(reason, fields.transient);
            if (fate === null) console.error("notifications: refused: leave=" + reason + " want=expire|invoke|dismiss|closed");
            else if (fate !== "keep") unlink(key, fate);
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
        bumpPanel();
        if (Logic.hasOwn(hovers, key)) {
            const next = Object.assign({}, hovers);
            delete next[key];
            hovers = next;
        }
        stopClock(key);
        countShown();
    }

    // The sender's own actions while the service holds its notification, as
    // { identifier, text }; none otherwise.
    function offered(key) {
        if (!Logic.hasOwn(held, key)) return [];
        try {
            return held[key].notification.actions.map(a => ({ identifier: a.identifier, text: a.text }));
        } catch (e) {
            return [];
        }
    }

    function windows() {
        return Hyprland.toplevels.values.map(t => ({
            address: t.address,
            appClass: t.wayland ? t.wayland.appId : (t.lastIpcObject && t.lastIpcObject.class) || ""
        }));
    }

    function entryFor(key) {
        const at = indexOf(key);
        if (at !== -1) return rowModel.get(at);
        for (const entry of store.history)
            if (entry.key === key) return entry;
        return null;
    }

    function actionsFor(key) {
        const entry = entryFor(key);
        if (entry === null) return [];
        return Logic.actionsFor(offered(key), Logic.senderWindows(windows(), entry).length > 0);
    }

    // A choice on a card, a toast's or an inbox row's: open, action:<id> or
    // dismiss. An open on a card whose VGS hints name a click
    // (NotificationLogic.clickRoute) opens the hinted file in the `open` TUI
    // or only dismisses; every other choice goes as
    // NotificationLogic.choicePlan says. Then the row leaves, bar an open
    // the TUI refuses, which keeps the row and shows why
    // (NotificationLogic.openOutcome).
    // The sender's window comes into view through the core's reveal, which
    // after a delivered action first gives the sender the chance to raise
    // it itself. Logs what the choice reached, with no content.
    function choose(key, choice) {
        const at = indexOf(key);
        const entry = at === -1 ? entryFor(key) : rowModel.get(at);
        if (entry === null) return false;
        const route = Logic.clickRoute(choice, entry);
        if (route === "open") {
            const reply = shell.tui.run("open", [entry.hintOpen]);
            const outcome = Logic.openOutcome(reply);
            if (outcome.leave) {
                leaveChosen(key, "invoke");
                return true;
            }
            console.warn("notifications: open " + reply);
            try {
                shell.toasts.show(outcome.notice);
            } catch (e) {
                console.error("notifications: open notice " + e.message);
            }
            return false;
        }
        if (route === "dismiss") {
            leaveChosen(key, "dismiss");
            return true;
        }
        const plan = Logic.choicePlan(choice, offered(key).map(a => a.identifier));
        if (plan === null) {
            console.error("notifications: refused: choice=" + choice + " want=open|action:<id>|dismiss");
            return false;
        }
        // Read before the delivery, after which the server may close the
        // notification and the toast start to leave.
        const senders = plan.raise ? Logic.senderWindows(windows(), entry) : [];
        let delivered = false;
        if (plan.deliver !== "") {
            try {
                const action = held[key].notification.actions.find(a => a.identifier === plan.deliver);
                action.invoke();
                delivered = true;
            } catch (e) {
                console.warn("notifications: action " + plan.deliver + " failed: " + e.message);
            }
        }
        if (senders.length > 0) {
            const reply = shell.compositor.reveal(senders, delivered);
            if (reply !== "ok") console.warn("notifications: reveal " + reply);
        }
        if (plan.raise) console.info("notifications: chose delivered=" + (delivered ? plan.deliver : "none") + " windows=" + senders.length);
        leaveChosen(key, plan.leave);
        return true;
    }

    function leaveChosen(key, reason) {
        const at = indexOf(key);
        if (at !== -1) {
            leave(key, reason);
            return;
        }
        if (reason === "dismiss") {
            store.dropHistory(key);
            if (Logic.hasOwn(held, key)) unlink(key, "dismiss");
            bumpPanel();
        }
    }

    // ------------------------------------------------------------ panel

    // The summon host judges whether the panel is open, as it does for the
    // core's IPC toggle; panelMode follows the panel for the clocks and
    // the subtitle and never decides an open.
    function togglePanel() {
        const reply = shell.surfaces.toggle("panel", JSON.stringify({ mode: "inbox" }));
        if (reply !== "ok") console.warn("notifications: panel " + reply);
        return reply;
    }

    function showPanel(mode) {
        const payload = JSON.stringify({ mode: mode === "history" ? "history" : "inbox" });
        const reply = shell.surfaces.summon("panel", payload);
        if (reply !== "ok") console.warn("notifications: panel " + reply);
        return reply;
    }

    function panelOpened(mode) {
        const next = mode === "history" ? "history" : "inbox";
        if (panelMode === next) return;
        panelMode = next;
        settle();
        bumpPanel();
    }

    function closePanel() {
        const reply = shell.surfaces.hide("panel");
        if (reply !== "ok") console.warn("notifications: panel " + reply);
        return reply;
    }

    function panelClosed() {
        if (panelMode === "") return;
        panelMode = "";
        panelFocused = false;
        settle();
        bumpPanel();
    }

    // Mark read: everything so far is read, and the panel closes.
    function markRead() {
        store.setReadBefore(Date.now());
        closePanel();
        bumpPanel();
    }

    // Clear history: the kept notifications go; the panel stays open and its
    // rows fade out.
    function clearHistoryPanel() {
        store.clearHistory();
        releaseUnstored("dismiss");
        bumpPanel();
    }

    function panelEntries() {
        const entries = [];
        const present = {};
        for (let i = 0; i < rowModel.count; i++) {
            const row = rowModel.get(i);
            if (row.leaving !== "") continue;
            if (panelMode === "history" || row.timestamp > store.readBefore) {
                entries.push(row);
                present[row.key] = true;
            }
        }
        const stored = Logic.panelRows(store.history, panelMode, store.readBefore);
        for (const entry of stored) {
            if (present[entry.key]) continue;
            entries.push(rowOf(entry, "panel"));
            present[entry.key] = true;
        }
        entries.sort((a, b) => b.timestamp - a.timestamp);
        return entries.slice(0, Logic.PANEL_ROWS_MAX);
    }

    function panelRow(entry) {
        const enrichment = Logic.enrich(entry.app, entry.desktopEntry, entry.appIcon, entry.summary, entry.body);
        const workspace = workspaceOf(enrichment);
        const out = {};
        for (const role of Logic.ENTRY_ROLES) out[role] = entry[role];
        out.origin = entry.origin || "panel";
        out.workspace = workspace;
        out.workspaceIcon = enrichment !== null ? workspaceIcon(enrichment.rule, workspace) : "";
        out.faceImages = enrichment !== null ? faceImages(enrichment, entry.image, workspace) : [];
        out.emoji = emojiFor(enrichment, workspace);
        out.actions = actionsFor(entry.key);
        return out;
    }

    function panelSnapshot() {
        const entries = panelEntries();
        return {
            mode: panelMode === "history" ? "history" : "inbox",
            subtitle: Logic.panelSubtitle(panelMode === "" ? "inbox" : panelMode, entries.length, store.status),
            silenced: store.dnd,
            rows: entries.map(panelRow)
        };
    }

    function hoverFromPanel(arg) {
        try {
            const request = JSON.parse(String(arg || "{}"));
            if (typeof request.key !== "string") return "refused: hover=key";
            hover(request.key, request.on === true);
            return "ok";
        } catch (e) {
            return "refused: hover=json";
        }
    }

    function chooseFromPanel(arg) {
        try {
            const request = JSON.parse(String(arg || "{}"));
            if (typeof request.key !== "string" || typeof request.choice !== "string") return "refused: choose=shape";
            const mode = panelMode === "history" ? "history" : "inbox";
            const left = choose(request.key, request.choice);
            if (panelOpen) showPanel(mode);
            return left ? "left" : "held";
        } catch (e) {
            return "refused: choose=json";
        }
    }

    // Close, as `how` says, every held notification whose entry the store
    // no longer keeps, trimmed off the history's end or cleared with it.
    function releaseUnstored(how) {
        for (const key of Logic.heldPastHistory(Object.keys(held), store.live, store.history)) unlink(key, how);
    }

    function releaseTrimmed() {
        releaseUnstored("expire");
    }

    // The store changes its lists one after the other when a toast leaves
    // into the history, so the held set is judged at the end of the turn.
    Connections {
        target: store
        function onLiveChanged() {
            Qt.callLater(root.releaseTrimmed);
            root.bumpPanel();
        }
        function onHistoryChanged() {
            Qt.callLater(root.releaseTrimmed);
            root.bumpPanel();
        }
        function onReadBeforeChanged() { root.bumpPanel(); }
        function onDndChanged() { root.bumpPanel(); }
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
            onScreen: rowKeys(() => true).length,
            history: store.history.length,
            held: Object.keys(held).length,
            readBefore: store.readBefore,
            duplicates: duplicates,
            slack: { photos: slackPhotos.photosEnabled, runs: slackPhotos.runs, idle: !slackPhotos.loading && !slackPhotos.loadPending, emoji: { on: slackPhotos.emojiEnabled, swaps: slackPhotos.emojiSwaps, teams: slackPhotos.emojiCounts() } }
        });
    }

    // Every held object goes back to the server as dismissed, since a
    // notification nobody draws would otherwise stay tracked; a toast stays
    // in the store and comes back restored, with no live actions.
    Component.onDestruction: {
        for (const key of Object.keys(held)) unlink(key, "dismiss");
        for (const key of Object.keys(silencedRefs)) releaseSilenced(key);
    }
}
