#!/usr/bin/env node
// The notifications' decisions, shell/plugins/vgs.notifications/
// NotificationLogic.js, under node: the body a card may render, Silence,
// lifetimes, entries and their image copies, the state file's judge, what a
// restart restores, the history's and the panel's limits, which toast a
// full stack lets go, the hover actions, the sender's window, the paused
// and running clocks, and the per-application rules that read a sender's
// workspace, people and workspace icons. Every expected value is written
// out by hand.
//
// The controls at the end edit a copy of the logic, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.notifications", "NotificationLogic.js");
// The plugin's look, whose face tints the logic names.
const appearance = load(path.join(__dirname, "..", "shell", "plugins", "vgs.notifications", "Appearance.js"));
const IMAGES = "/state/vgs/notifications/images";
// The logic runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);

// An entry as the state file stores it.
function stored(timestamp, id, extra) {
    return Object.assign({ key: timestamp + "-" + id, originalId: id, app: "app", appIcon: "", summary: "s" + id, body: "", image: "", desktopEntry: "", urgency: 1, expireTimeout: 0, timestamp: timestamp }, extra || {});
}
function stateText(value) {
    return JSON.stringify(Object.assign({ version: 1, dnd: false, readBefore: 0, live: [], history: [] }, value));
}

// Bodies: [label, body, app, what the card renders].
const BODIES = [
    ["plain text", "hello", "app", "hello"],
    ["a remote image tag", 'a <img src="http://h/x.png"> b', "app", "a  b"],
    ["an image tag in capitals", 'a <IMG SRC="http://h/x.png"> b', "app", "a  b"],
    ["an image tag behind a NEL", "a <\u0085img src=\"http://h/x.png\"> b", "app", "a  b"],
    // One malformed tag named `im` to Qt as to the stripper: kept whole, and
    // nothing is spliced into a live image tag.
    ["a nested decoy", '<im<img src="http://a/decoy.png">g src="http://a/beacon.png">', "app", '<im<img src="http://a/decoy.png">g src="http://a/beacon.png">'],
    ["markup kept", "<b>bold</b> <i>it</i>", "app", "<b>bold</b> <i>it</i>"],
    ["newlines become breaks", "one\ntwo\r\nthree", "app", "one<br/>two<br/>three"],
    ["a break that would open an image", "<x\n<img src=\"http://h/x.png\">", "app", "<x<br/>"],
    ["an unterminated image tag", 'a <img src="http://h', "app", "a "],
    ["a Chromium site address", "<a href=\"https://chat.example.com\">chat.example.com</a> Hi there", "Google Chrome", "Hi there"],
    ["a bare Chromium site address", "chat.example.com Hi there", "chromium", "Hi there"],
    ["a site address from another sender", "chat.example.com Hi there", "app", "chat.example.com Hi there"]
];

// State files the judge refuses: [label, text, the error].
const STATE_REFUSED = [
    ["an empty file", "", "not-json"],
    ["not JSON", "{ nope", "not-json"],
    ["a list", "[]", "not-object"],
    ["an unknown key", stateText({ extra: 1 }), "extra unknown"],
    ["another version", stateText({ version: 2 }), "version want=1"],
    ["a Silence that is no boolean", stateText({ dnd: "on" }), "dnd want=boolean"],
    ["a read cutoff that is no number", stateText({ readBefore: "0" }), "readBefore want=number"],
    ["a history that is no list", stateText({ history: {} }), "history want=list"],
    ["a history past its limit", stateText({ history: Array.from({ length: 101 }, (_, i) => stored(1000 + i, i)) }), "history length=101 want<=100"],
    ["a live list past its limit", stateText({ live: Array.from({ length: 21 }, (_, i) => stored(1000 + i, i)) }), "live length=21 want<=20"],
    ["an entry that is no object", stateText({ history: [3] }), "history.0 want=object"],
    ["an entry with an unknown key", stateText({ history: [stored(5, 1, { extra: 1 })] }), "history.0.extra unknown"],
    ["a summary that is no string", stateText({ history: [stored(5, 1, { summary: 3 })] }), "history.0.summary want=string"],
    ["a timestamp that is no number", stateText({ live: [stored(5, 1, { timestamp: "5" })] }), "live.0.timestamp want=number"],
    ["an unknown urgency", stateText({ history: [stored(5, 1, { urgency: 7 })] }), "history.0.urgency want=0|1|2"],
    ["a key that is not its identity", stateText({ history: [stored(5, 1, { key: "6-1" })] }), "history.0.key want=5-1"],
    ["a deadline that is no number", stateText({ live: [stored(5, 1, { deadline: "9" })] }), "live.0.deadline want=number"],
    ["a remaining time that is no number", stateText({ live: [stored(5, 1, { remaining: null })] }), "live.0.remaining want=number"],
    ["a clock both running and paused", stateText({ live: [stored(5, 1, { deadline: 9, remaining: 3 })] }), "live.0 deadline and remaining both set"],
    ["a key twice", stateText({ live: [stored(5, 1)], history: [stored(5, 1)] }), "history.0.key duplicate"]
];

// Senders a rule reads, in the title forms Slack's web client builds:
// [label, app, desktop entry, summary, body, what the card draws].
const ENRICHED = [
    ["a direct message", "Slack", "slack", "[acme] from Ada Lovelace", "Lunch?", { rule: "slack", workspace: "acme", title: "from Ada Lovelace", faces: ["Ada Lovelace"], more: 0 }],
    ["a channel message", "Slack", "slack", "[acme] in eng-core", "Grace Hopper (Navy): shipped", { rule: "slack", workspace: "acme", title: "in eng-core", faces: ["Grace Hopper (Navy)"], more: 0 }],
    ["a channel message with no sender", "Slack", "slack", "[acme] in eng-core", "shipped", { rule: "slack", workspace: "acme", title: "in eng-core", faces: [], more: 0 }],
    ["a group message, sender first and once", "Slack", "slack", "[acme] in ada, grace, alan, edsger, barbara", "Grace: hi all", { rule: "slack", workspace: "acme", title: "in ada, grace, alan, edsger, barbara", faces: ["Grace", "ada", "alan"], more: 2 }],
    ["a group message of three", "Slack", "slack", "[acme] in ada, grace", "alan: hi", { rule: "slack", workspace: "acme", title: "in ada, grace", faces: ["alan", "ada", "grace"], more: 0 }],
    ["one workspace, a direct message", "Slack", "slack", "New message from Ada", "hi", { rule: "slack", workspace: "", title: "New message from Ada", faces: ["Ada"], more: 0 }],
    ["one workspace, a thread", "Slack", "slack", "New thread message in eng", "Ada: hi", { rule: "slack", workspace: "", title: "New thread message in eng", faces: ["Ada"], more: 0 }],
    ["past Do Not Disturb", "Slack", "slack", "Ada is trying to reach you", "urgent", { rule: "slack", workspace: "", title: "Ada is trying to reach you", faces: ["Ada"], more: 0 }],
    ["an unknown title under a workspace", "Slack", "slack", "[acme] Reminder: standup", "", { rule: "slack", workspace: "acme", title: "Reminder: standup", faces: [], more: 0 }],
    ["an unknown title", "Slack", "slack", "Reminder: standup", "", null],
    ["matched by the desktop entry alone", "Electron", "slack", "[acme] from Ada", "", { rule: "slack", workspace: "acme", title: "from Ada", faces: ["Ada"], more: 0 }],
    ["matched by the flatpak's name", "com.slack.Slack", "", "[acme] from Ada", "", { rule: "slack", workspace: "acme", title: "from Ada", faces: ["Ada"], more: 0 }],
    ["another sender unchanged", "Chat", "chat", "[acme] from Ada", "", null]
];

function verify(logic) {
    for (const [label, body, app, want] of BODIES)
        assert.equal(logic.styledBody(body, app, ""), want, "styled body: " + label);
    assert.equal(logic.sanitizeBody("", "app", ""), "", "an empty body stays empty");
    assert.equal(logic.summaryStartsWithGlyph("\u{f0e0}  Mail"), true, "a glyph and two spaces open the summary");
    assert.equal(logic.summaryStartsWithGlyph("M  ail"), true, "any first character counts, as the reference reads it");
    assert.equal(logic.summaryStartsWithGlyph("Mail today"), false, "one space is text");
    assert.equal(logic.summaryStartsWithGlyph(""), false, "an empty summary has no glyph");

    // Silence lets a critical notification from the bare command line through.
    const U = logic.URGENCY;
    assert.equal(logic.bypassesSilence("notify-send", U.critical), true);
    assert.equal(logic.bypassesSilence("notify-send", U.normal), false);
    assert.equal(logic.bypassesSilence("Slack", U.critical), false, "a chat app marking everything critical stays silenced");
    assert.equal(logic.isEphemeral("notify-send", false), true);
    assert.equal(logic.isEphemeral("app", true), true, "a transient notification is not kept");
    assert.equal(logic.isEphemeral("app", false), false);

    // Lifetimes: [urgency, sender's timeout, the duration setting in
    // milliseconds, milliseconds shown].
    for (const [urgency, asked, normal, want] of [[U.low, 0, 8000, 5000], [U.low, 7000, 8000, 7000], [U.normal, 0, 8000, 8000], [U.normal, 3000, 8000, 8000], [U.normal, 12000, 8000, 12000], [U.normal, 90000, 8000, 30000], [U.critical, 5000, 8000, 0], [U.normal, -1, 8000, 8000], [U.normal, NaN, 8000, 8000],
        [U.normal, 0, 3000, 3000], [U.normal, 0, 20000, 20000], [U.normal, 12000, 20000, 20000], [U.low, 0, 3000, 3000], [U.low, 0, 20000, 5000], [U.critical, 0, 3000, 0]])
        assert.equal(logic.lifetimeFor(urgency, asked, normal), want, `lifetime of urgency ${urgency} asking ${asked} under ${normal}`);

    // Entries.
    const fields = { id: 7, appName: "Chat", appIcon: "chat", summary: "Hi", body: "b", image: "image://icon//tmp/a.png", desktopEntry: "chat", urgency: U.critical, expireTimeout: 4000 };
    same(logic.entryOf(fields, 1000, null), { key: "1000-7", originalId: 7, app: "Chat", appIcon: "chat", summary: "Hi", body: "b", image: "file:///tmp/a.png", desktopEntry: "chat", urgency: 2, expireTimeout: 4000, timestamp: 1000 });
    assert.equal(logic.entryOf(fields, 1000, k => k === "1000-7" || k === "1001-7").key, "1002-7", "a taken key moves the timestamp on");
    assert.equal(logic.entryOf({ id: 1, urgency: 9 }, 5, null).urgency, U.normal, "an unknown urgency is normal");
    assert.equal(logic.entryOf({ id: 1, summary: "x".repeat(600) }, 5, null).summary.length, 512, "a summary is cut at its limit");
    assert.equal(logic.entryOf({ id: 1, body: "x".repeat(5000) }, 5, null).body.length, 4096, "a body is cut at its limit");
    assert.equal(logic.entryOf({ id: 1, expireTimeout: -5 }, 5, null).expireTimeout, 0, "a negative timeout is none");
    const original = logic.entryOf(fields, 1000, null);
    const updated = logic.updatedEntry(original, Object.assign({}, fields, { id: 99, summary: "Hello" }));
    same([updated.key, updated.originalId, updated.timestamp, updated.summary], ["1000-7", 7, 1000, "Hello"], "an update keeps the identity");
    assert.equal(logic.entryChanged(original, updated), true);
    assert.equal(logic.entryChanged(original, logic.updatedEntry(original, fields)), false, "the same content is no change");

    // Image values: [value, local file].
    for (const [value, want] of [["/tmp/a.png", "/tmp/a.png"], ["file:///tmp/a%20b.png", "/tmp/a b.png"], ["image://icon//tmp/a.png", "/tmp/a.png"], ["image://icon/firefox", ""], ["image://qsimage/3", ""], ["firefox", ""], ["", ""], ["file://%E0%A4%A", ""]])
        assert.equal(logic.localImageFile(value), want, "local file of " + JSON.stringify(value));
    same(logic.drawnImage("image://icon//tmp/a.png"), "file:///tmp/a.png");
    same(logic.drawnImage("firefox"), "firefox");
    const entry = stored(1000, 7, { appIcon: "file:///usr/share/icons/chat.png", image: "image://qsimage/3" });
    same(logic.persistable(entry, IMAGES), {
        entry: stored(1000, 7, { appIcon: "file://" + IMAGES + "/1000-7-appIcon", image: "" }),
        copies: [{ from: "/usr/share/icons/chat.png", to: IMAGES + "/1000-7-appIcon" }]
    }, "a file is copied, an in-process image dropped");
    const again = logic.persistable(logic.persistable(entry, IMAGES).entry, IMAGES);
    same(again.copies, [], "an entry already pointing at its copies needs none");
    same(logic.persistable(stored(1, 2, { appIcon: "chat" }), IMAGES).entry.appIcon, "chat", "an icon name stays a name");
    same(logic.ownedImages([again.entry, stored(5, 1, { image: "file://" + IMAGES + "/5-1-image" }), stored(6, 1, { image: "file:///elsewhere/6-1-image.png" })]), ["1000-7-appIcon", "5-1-image"]);

    // The state file's judge.
    for (const [label, text, want] of STATE_REFUSED)
        same(logic.parseState(text), { ok: false, error: want }, "state: " + label);
    const good = { version: 1, dnd: true, readBefore: 50, live: [stored(9, 2, { deadline: 99 })], history: [stored(5, 1)] };
    same(logic.parseState(JSON.stringify(good)), { ok: true, state: { dnd: true, readBefore: 50, live: good.live, history: good.history } });
    same(logic.parseState(logic.serializeState(logic.emptyState())), { ok: true, state: { dnd: false, readBefore: 0, live: [], history: [] } }, "an empty state reads back");
    same(logic.parseState(logic.serializeState({ dnd: true, readBefore: 50, live: good.live, history: good.history })).state.history, good.history, "a state reads back as written");

    // Restart: a toast whose time ran out goes into the history; one that
    // survives restarts with a whole lifetime as a deadline.
    const now = 100000;
    const plan = logic.restorePlan([
        stored(now - 9000, 1),
        stored(now - 3000, 2),
        stored(now - 60000, 3, { urgency: U.critical }),
        stored(now - 60000, 4, { deadline: now + 500 }),
        stored(now - 1000, 5, { deadline: now - 1 }),
        stored(now - 60000, 6, { urgency: U.low, remaining: 2000 })
    ], now, 8000);
    same(plan.expired.map(e => e.key), [(now - 9000) + "-1", (now - 1000) + "-5"]);
    same(plan.show.map(e => [e.key, e.deadline === undefined ? null : e.deadline]), [[(now - 3000) + "-2", now + 8000], [(now - 60000) + "-3", null], [(now - 60000) + "-4", now + 8000], [(now - 60000) + "-6", now + 5000]], "a paused clock has not run out");
    assert.equal("remaining" in plan.show[3], false, "a toast shown again keeps no paused time");
    same(logic.clockFields({ remaining: 400, since: null }), { remaining: 400 });
    same(logic.clockFields({ remaining: 400, since: 1000 }), { deadline: 1400 });
    assert.equal("deadline" in plan.expired[1], false, "an expired entry leaves its deadline behind");

    // History: newest first, each key once, a hundred at most.
    const pushed = logic.pushHistory([stored(10, 1), stored(5, 2)], [stored(10, 1, { summary: "again" }), stored(20, 3, { deadline: 5 })]);
    same(pushed.history.map(e => [e.key, e.summary]), [["20-3", "s3"], ["10-1", "again"], ["5-2", "s2"]]);
    assert.equal("deadline" in pushed.history[0], false, "the history keeps no deadline");
    const full = Array.from({ length: 100 }, (_, i) => stored(1000 - i, i));
    const over = logic.pushHistory(full, [stored(2000, 500)]);
    same([over.history.length, over.history[0].key, over.dropped.map(e => e.key)], [100, "2000-500", ["901-99"]], "the oldest goes past the limit");

    // Panels: the inbox after the cutoff, the history whole, forty at most.
    const kept = Array.from({ length: 60 }, (_, i) => stored(600 - i, i));
    same(logic.panelRows(kept, "inbox", 590).map(e => e.timestamp), [600, 599, 598, 597, 596, 595, 594, 593, 592, 591]);
    same(logic.panelRows(kept, "history", 590).length, 40);
    same(logic.panelRows(kept, "inbox", 0).length, 40);
    same(logic.panelRows([], "inbox", 0), []);
    for (const [mode, count, state, want] of [["inbox", 0, "loaded", "All caught up"], ["history", 0, "absent", "Nothing kept yet"], ["inbox", 1, "loaded", "1 notification"], ["history", 3, "loaded", "3 notifications"], ["inbox", 2, "corrupt", "History unavailable: corrupt"]])
        assert.equal(logic.panelSubtitle(mode, count, state), want, `subtitle ${mode} ${count} ${state}`);

    // Eviction: the oldest that is not critical, or the oldest of all.
    assert.equal(logic.evictionKey([{ key: "new", urgency: U.normal }, { key: "mid", urgency: U.low }, { key: "old", urgency: U.critical }]), "mid");
    assert.equal(logic.evictionKey([{ key: "new", urgency: U.critical }, { key: "old", urgency: U.critical }]), "old");
    assert.equal(logic.evictionKey([]), "");

    // Actions: the sender's own, Show when it has none and a window is open,
    // and Dismiss.
    same(logic.actionsFor([{ identifier: "default", text: "" }, { identifier: "reply", text: "Reply" }, { identifier: "", text: "x" }], true), [{ id: "action:default", label: "Open" }, { id: "action:reply", label: "Reply" }, { id: "dismiss", label: "Dismiss" }]);
    same(logic.actionsFor([], true), [{ id: "focus", label: "Show" }, { id: "dismiss", label: "Dismiss" }]);
    same(logic.actionsFor([], false), [{ id: "dismiss", label: "Dismiss" }]);

    // The sender's window: its desktop entry, then its name, case folded.
    const windows = [{ address: "abc", appClass: "Firefox" }, { address: "0xdef", appClass: "org.chat.App" }, { address: "", appClass: "chat" }];
    assert.equal(logic.focusAddress(windows, "org.chat.app", "Chat"), "0xdef");
    assert.equal(logic.focusAddress(windows, "", "firefox"), "0xabc");
    assert.equal(logic.focusAddress(windows, "", "chat"), "", "a window with no address yet is not focused");
    assert.equal(logic.focusAddress(windows, "", "notify-send"), "", "the command line owns no window");
    assert.equal(logic.focusAddress([], "x", "y"), "");

    // Clocks: a paused clock keeps what is left; a running one is charged
    // for the time it ran.
    let clocks = { a: { remaining: 5000, since: null }, b: { remaining: 3000, since: null } };
    clocks = logic.settleClocks(clocks, key => key === "a", 1000);
    same(clocks, { a: { remaining: 5000, since: 1000 }, b: { remaining: 3000, since: null } });
    same(logic.nextExpiry(clocks, 2000), { key: "a", wait: 4000 });
    clocks = logic.settleClocks(clocks, () => false, 2500);
    same(clocks, { a: { remaining: 3500, since: null }, b: { remaining: 3000, since: null } }, "a clock that stops is charged");
    assert.equal(logic.nextExpiry(clocks, 3000), null, "no running clock runs out");
    clocks = logic.settleClocks(clocks, () => true, 3000);
    same(logic.nextExpiry(clocks, 6100), { key: "b", wait: 0 }, "an overdue clock waits no longer");
    same(logic.settleClocks(clocks, () => true, 9999), JSON.parse(JSON.stringify(clocks)), "a running clock that keeps running is left");

    // Silence over IPC.
    for (const [arg, current, want] of [["on", false, { ok: true, dnd: true }], ["OFF", true, { ok: true, dnd: false }], ["toggle", true, { ok: true, dnd: false }], ["", true, { ok: true, dnd: true }], ["loud", false, { ok: false }]])
        same(logic.silenceArgument(arg, current), want, "silence " + JSON.stringify(arg));

    // Enrichment: what a card draws for a sender a rule reads.
    for (const [label, app, entry, summary, body, want] of ENRICHED)
        same(logic.enrich(app, entry, summary, body), want, "enrich: " + label);
    for (const [name, want] of [["Ada Lovelace", "AL"], ["ada", "A"], ["Ada (she/her)", "A"], ["Grace B. Hopper (Navy)", "GH"], ["@ada", "A"], ["\u{1F600} Bot", "\u{1F600}B"], ["", "?"], ["(x)", "?"]])
        assert.equal(logic.initialsOf(name), want, "initials of " + JSON.stringify(name));
    // Face tints, as Python worked them out from the stated hash.
    for (const [name, want] of [["ada", "magenta"], ["Ada", "magenta"], [" ada ", "magenta"], ["grace", "rose"], ["alan", "blue"], ["edsger", "teal"], ["barbara", "green"], ["", "coral"]])
        assert.equal(logic.faceTint(name), want, "tint of " + JSON.stringify(name));
    same(Object.keys(appearance.TOKENS.face.tint), ["coral", "amber", "green", "blue", "indigo", "magenta", "teal", "rose"], "the look holds every tint");
    same(logic.FACE_TINTS, ["coral", "amber", "green", "blue", "indigo", "magenta", "teal", "rose"]);
    // A card at its tallest keeps a content corner, `pad` in from both
    // edges, inside the capsule's round end of radius maxHeight / 2.
    const card = appearance.TOKENS.card;
    assert.ok(card.pad.value >= (1 - Math.SQRT1_2) / 2 * card.maxHeight.value, `card.pad=${card.pad.value} leaves a corner outside a ${card.maxHeight.value} px capsule's end`);
    same(logic.workspaceRuleIds(), ["slack"]);
    assert.equal(logic.enricherById("slack").id, "slack");
    assert.equal(logic.enricherById("none"), null);

    // Slack's workspace list: team-id order, the larger icon first, unsafe
    // ids and nameless entries skipped and counted.
    const index = { workspaces: {
        T2: { domain: "globex", name: "Globex", icon: { image_68: "https://a/g68.png", image_88: "https://a/g88.png" } },
        T1: { domain: "acme", name: "Acme Corp", icon: { image_68: "https://a/a68.png" } },
        "../x": { domain: "evil", name: "Evil" },
        T3: { domain: "", name: "" },
        T4: { domain: "initech", icon: { image_88: "http://a/plain.png", image_68: "https://a/has space.png" } }
    } };
    same(logic.slackWorkspaces(JSON.stringify(index)), { ok: true, skipped: 2, workspaces: [
        { id: "T1", names: ["acme", "Acme Corp"], urls: ["https://a/a68.png"] },
        { id: "T2", names: ["globex", "Globex"], urls: ["https://a/g88.png", "https://a/g68.png"] },
        { id: "T4", names: ["initech"], urls: [] }
    ] });
    same(logic.slackWorkspaces("{"), { ok: false, error: "not-json" });
    same(logic.slackWorkspaces("{\"workspaces\": []}"), { ok: false, error: "workspaces want=object" });
    const many = { workspaces: {} };
    for (let i = 10; i < 30; i++) many.workspaces["T" + i] = { domain: "w" + i };
    same(logic.slackWorkspaces(JSON.stringify(many)).workspaces.map(w => w.id), Array.from({ length: 16 }, (_, i) => "T" + (10 + i)), "the list is cut at its limit");
    const listed = logic.slackWorkspaces(JSON.stringify(index)).workspaces;
    same(logic.workspaceCopies(listed, "/c"), [{ to: "/c/T1-0", url: "https://a/a68.png" }, { to: "/c/T2-0", url: "https://a/g88.png" }, { to: "/c/T2-1", url: "https://a/g68.png" }]);
    const icons = logic.workspaceIconMap(listed, "/c", ["/c/T2-1?v=0123456789abcdef", "/c/T9-0?v=abcdef0123456789"]);
    same(icons, { acme: "", "acme corp": "", globex: "file:///c/T2-1?v=0123456789abcdef", initech: "" }, "a workspace answers to its first copied icon, by domain and by name");
    same(logic.workspaceIconMap([{ id: "A", names: ["x"], urls: ["u"] }, { id: "B", names: ["X"], urls: ["u"] }], "/c", ["/c/B-0?v=0123456789abcdef"]), { x: "" }, "a shared name keeps the first workspace");
    // Reading the list again: [label, workspace, last read, now, want].
    for (const [label, workspace, loadedAt, now, want] of [
        ["one with an icon", "Globex", 0, 999999, false],
        ["one the list does not name", "hooli", 1000, 61000, true],
        ["one the list does not name, read a moment ago", "hooli", 1000, 60999, false],
        ["one with no icon", "acme", 0, 60000, true],
        ["no workspace", "", 0, 999999, false]
    ])
        assert.equal(logic.workspaceReload(icons, workspace, loadedAt, now), want, "reload for " + label);

    const photoCache = {
        status: "loaded",
        teams: [{
            id: "T1",
            names: ["acme", "Acme Corp"],
            icon: "file:///cache/T1/workspace.png?v=0123456789abcdef",
            users: [
                { id: "U1", names: ["Ada Lovelace", "ada"], photo: "file:///cache/T1/U1.png?v=abcdef0123456789" },
                { id: "U2", names: ["Grace Hopper"], photo: "file:///cache/T1/U2.png?v=1234567890abcdef" },
                { id: "U3", names: ["No Photo"], photo: "" }
            ]
        }]
    };
    same(logic.slackPhotos(JSON.stringify(photoCache)), { ok: true, status: "loaded", generatedAt: 0, downloadFailed: 0, stale: false, teams: photoCache.teams }, "a Slack photo cache is accepted");
    same(logic.slackPhotos(JSON.stringify({ status: "absent" })), { ok: true, status: "absent", generatedAt: 0, downloadFailed: 0, stale: false, teams: [] }, "no token leaves no cache");
    same(logic.slackPhotos("{"), { ok: false, error: "not-json" });
    same(logic.slackPhotos(JSON.stringify({ status: "stale" })), { ok: false, error: "status want=loaded|absent" });
    same(logic.slackPhotos(JSON.stringify({ status: "loaded", teams: [{ id: "../x", names: ["x"], users: [] }] })), { ok: false, error: "teams.0.id want=safe" });
    same(logic.slackPhotos(JSON.stringify({ status: "loaded", generatedAt: 123, downloadFailed: 2, stale: true, teams: [{ id: "T1", names: ["acme"], users: [{ id: "U1", names: ["Ada"], photo: "https://example.test/a.png" }] }] })), { ok: true, status: "loaded", generatedAt: 123, downloadFailed: 2, stale: true, teams: [{ id: "T1", names: ["acme"], icon: "", users: [{ id: "U1", names: ["Ada"], photo: "" }] }] }, "a non-file photo is ignored");
    same(logic.slackPhotos(JSON.stringify({ status: "loaded", teams: [{ id: "T1", names: ["acme"], icon: "file:///cache/T1/workspace.png", users: [{ id: "U1", names: ["Ada"], photo: "file:///cache/T1/U1.png" }] }] })).teams, [{ id: "T1", names: ["acme"], icon: "", users: [{ id: "U1", names: ["Ada"], photo: "" }] }], "an unversioned file URL is ignored");
    const group = logic.enrich("Slack", "slack", "[acme] in Ada Lovelace, Grace Hopper, No Photo", "Ada Lovelace: hi");
    same(logic.slackFaceImages(group, photoCache.teams, "file:///sender.png"), ["file:///cache/T1/U1.png?v=abcdef0123456789", "file:///cache/T1/U2.png?v=1234567890abcdef", ""], "each Slack face takes its own photo");
    same(logic.slackFaceImages(Object.assign({}, group, { workspace: "unknown" }), photoCache.teams, "file:///sender.png"), ["file:///sender.png", "", ""], "an unknown workspace has no photos");
    const singleTeam = [{ id: "T1", names: ["acme"], icon: "", users: [{ id: "U1", names: ["Ada"], photo: "file:///cache/T1/U1.png?v=abcdef0123456789" }] }];
    const direct = logic.enrich("Slack", "slack", "New message from Ada", "hi");
    same(logic.slackFaceImages(direct, singleTeam, ""), ["file:///cache/T1/U1.png?v=abcdef0123456789"], "one workspace can match titles without a prefix");
    same(logic.slackFaceImages(direct, [{ id: "T1", names: ["acme"], icon: "", users: [{ id: "U1", names: ["Ada"], photo: "file:///first.png?v=1111111111111111" }, { id: "U2", names: ["ADA"], photo: "file:///second.png?v=2222222222222222" }] }], ""), ["file:///first.png?v=1111111111111111"], "the first duplicate name owns the photo");
    assert.equal(logic.slackWorkspaceIcon(photoCache.teams, "acme"), "file:///cache/T1/workspace.png?v=0123456789abcdef");
    // The probe's stdout: one line per state token-status.sh prints, and
    // anything else read as no answer.
    const TOKEN_LINES = [
        ["slack-token: present\n", "present"],
        ["slack-token: absent\n", "absent"],
        ["slack-token: locked\n", "locked"],
        ["slack-token: unavailable reason=secret-tool-missing\n", "unavailable"],
        ["slack-token: unavailable reason=search-failed status=1\n", "unavailable"],
        ["slack-token: present", "present"],
        ["slack-token: unsafe\n", ""],
        ["slack-token: presently\n", ""],
        ["slack-token: present\nslack-token: absent\n", ""],
        ["secret = xoxp-1\nslack-token: present\n", ""],
        ["", ""]
    ];
    for (const [text, want] of TOKEN_LINES) assert.equal(logic.slackTokenState(text), want, "slackTokenState " + JSON.stringify(text));
}
verify(load(file));

// Each control removes one rule from a copy of the logic and keeps the text
// around it. The suite must fail on every copy.
const CONTROLS = [
    ["image tag", 'return !!name && name[1].toLowerCase() === "img";', "return false;"],
    ["strip after the newline rewrite", 'return stripImageTags(sanitizeBody(body, app, appIcon).replace(/\\r\\n|\\r|\\n/g, "<br/>"));', 'return sanitizeBody(body, app, appIcon).replace(/\\r\\n|\\r|\\n/g, "<br/>");'],
    ["Chromium address", "if (!isChromiumDerived(app, appIcon)) return text;", "return text;"],
    ["Silence exception", 'return String(appName || "") === "notify-send" && urgency === URGENCY.critical;', 'return String(appName || "") === "notify-send";'],
    ["critical stays", "if (urgency === URGENCY.critical) return 0;", ""],
    ["lifetime ceiling", "return Math.min(MAX_LIFETIME, Math.max(floor, Math.round(asked)));", "return Math.max(floor, Math.round(asked));"],
    ["the duration setting is the normal floor", "var floor = urgency === URGENCY.low ? Math.min(LOW_LIFETIME, normal) : normal;", "var floor = urgency === URGENCY.low ? Math.min(LOW_LIFETIME, normal) : 8000;"],
    ["a low toast stays no longer than the setting", "Math.min(LOW_LIFETIME, normal)", "LOW_LIFETIME"],
    ["key clash", "while (taken && taken(keyOf(at, id))) at += 1;", ""],
    ["summary limit", "summary: clip(f.summary, SUMMARY_MAX),", "summary: String(f.summary || \"\"),"],
    ["icon provider path", 'if (s.indexOf(ICON_PROVIDER) === 0 && s.charAt(ICON_PROVIDER.length) === "/") return s.slice(ICON_PROVIDER.length);', ""],
    ["in-process image dropped", '} else if (value.indexOf("image://") === 0) {\n            out[role] = "";', '} else if (false) {\n            out[role] = "";'],
    ["copy once", "if (source !== copy) copies.push({ from: source, to: copy });", "copies.push({ from: source, to: copy });"],
    ["history limit", "if (list.length > limits[lists[l]]) return", "if (false) return"],
    ["entry key identity", 'if (value.key !== keyOf(value.timestamp, value.originalId)) return where + ".key want="', 'if (false) return where + ".key want="'],
    ["duplicate key", 'if (seen[list[i].key]) return { ok: false, error: lists[l] + "." + i + ".key duplicate" };', ""],
    ["unknown state key", 'if (["version", "dnd", "readBefore", "live", "history"].indexOf(keys[k]) === -1) return', "if (false) return"],
    ["deadline outranks arrival", ": entry.deadline !== undefined ? now >= entry.deadline", ": false"],
    ["whole lifetime on restore", "if (lifetime > 0) kept.deadline = now + lifetime;", ""],
    ["a paused clock survives", "var over = entry.remaining !== undefined ? false", "var over = entry.remaining !== undefined ? true"],
    ["paused or running", 'if (value.deadline !== undefined && value.remaining !== undefined) return where + " deadline and remaining both set";', ""],
    ["clock fields", "return clock.since === null ? { remaining: clock.remaining } : { deadline: clock.since + clock.remaining };", "return { deadline: clock.since + clock.remaining };"],
    ["history newest first", "merged.sort(function (a, b) { return b.timestamp - a.timestamp; });", ""],
    ["history cut", "return { history: merged.slice(0, HISTORY_MAX), dropped: merged.slice(HISTORY_MAX) };", "return { history: merged, dropped: [] };"],
    ["inbox cutoff", 'var rows = mode === "inbox" ? history.filter(function (e) { return e.timestamp > readBefore; }) : history.slice();', "var rows = history.slice();"],
    ["panel limit", "return rows.slice(0, PANEL_ROWS_MAX);", "return rows;"],
    ["evict non-critical first", "if (rows[i].urgency !== URGENCY.critical) return rows[i].key;", ""],
    ["Show without actions", 'if (list.length === 0 && canFocus) list.push({ id: "focus", label: "Show" });', ""],
    ["charge a stopping clock", "next[keys[i]] = { remaining: Math.max(0, c.remaining - (now - c.since)), since: null };", "next[keys[i]] = { remaining: c.remaining, since: null };"],
    ["paused clocks wait", "if (c.since === null) continue;", ""],
    ["rule by desktop entry", 'var wanted = [String(desktopEntry || "").toLowerCase(), String(app || "").toLowerCase()];\n    for (var r = 0;', 'var wanted = [String(app || "").toLowerCase()];\n    for (var r = 0;'],
    ["faces cap", "faces: read.people.slice(0, FACES_MAX),", "faces: read.people,"],
    ["workspace prefix", "workspace = bracket[1];\n        rest = bracket[2];", "workspace = bracket[1];"],
    ["group members", 'var members = within[1].indexOf(",") === -1 ? [] :', "var members = true ? [] :"],
    ["sender once", "if (sender === \"\" || fold(members[i]) !== fold(sender)) people.push(members[i]);", "people.push(members[i]);"],
    ["initials skip a parenthesis", '.replace(/\\([^)]*\\)/g, " ")', ""],
    ["safe team id", "if (!/^[A-Za-z0-9]{1,32}$/.test(ids[i]) || names.length === 0) {", "if (names.length === 0) {"],
    ["larger icon first", "var urls = [icon.image_88, icon.image_68]", "var urls = [icon.image_68, icon.image_88]"],
    ["workspace limit", "for (var i = 0; i < ids.length && out.length < WORKSPACES_MAX; i++) {", "for (var i = 0; i < ids.length; i++) {"],
    ["first copied icon", "if (copiedUrl !== \"\") file = \"file://\" + copiedUrl;", "file = \"file://\" + to;"],
    ["reload gap", "return now - loadedAt >= WORKSPACE_RELOAD_GAP;", "return true;"],
    ["tint by the folded name", 'var key = fold(name || "");', 'var key = String(name || "");'],
    ["tint by the hash", "return FACE_TINTS[hash % FACE_TINTS.length];", "return FACE_TINTS[0];"],
    ["Slack photo cache status", 'if (parsed.status !== "loaded") return { ok: false, error: "status want=loaded|absent" };', 'if (false) return { ok: false, error: "status want=loaded|absent" };'],
    ["Slack photo safe team id", 'if (typeof team.id !== "string" || !/^[A-Za-z0-9]{1,32}$/.test(team.id)) return { ok: false, error: "teams." + t + ".id want=safe" };', 'if (false) return { ok: false, error: "teams." + t + ".id want=safe" };'],
    ["Slack photo file URL only", 'return typeof value === "string" && /^file:\\/\\/\\/[^\\s?#]+\\.png\\?v=[0-9a-f]{16}$/.test(value) ? value : "";', 'return typeof value === "string" ? value : "";'],
    ["Slack photo workspace match", "if (fold(teams[t].names[n]) === wanted) return teams[t];", "if (false) return teams[t];"],
    ["Slack photo first name wins", "if (!hasOwn(map, key)) map[key] = photo;", "map[key] = photo;"],
    ["the Slack token state is one of the probe's", "return match !== null && SLACK_TOKEN_STATES.indexOf(match[1]) !== -1 ? match[1] : \"\";", "return match !== null ? match[1] : \"\";"],
    ["the Slack token line is the whole output", "var match = /^slack-token: ([a-z]+)(?: [^\\n]*)?\\n?$/.exec(String(text));", "var match = /slack-token: ([a-z]+)/.exec(String(text));"],
    ["Slack photo per face", "images.push(hasOwn(map, key) ? map[key] : (i === 0 ? String(carriedImage || \"\") : \"\"));", "images.push(i === 0 ? String(carriedImage || \"\") : \"\");"]
];

const source = fs.readFileSync(file, "utf8");
const temp = path.join(__dirname, "..", "tmp", "notifications-logic-control-" + process.pid);
fs.rmSync(temp, { recursive: true, force: true });
fs.mkdirSync(temp, { recursive: true });
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "NotificationLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on logic without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-notifications-logic: ok bodies=${BODIES.length} states=${STATE_REFUSED.length} enriched=${ENRICHED.length} controls=${CONTROLS.length}`);
