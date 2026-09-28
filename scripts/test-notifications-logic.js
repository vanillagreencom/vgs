#!/usr/bin/env node
// The notifications' decisions, shell/plugins/vgs.notifications/
// NotificationLogic.js, under node: the body a card may render, Silence,
// lifetimes, entries and their image copies, the state file's judge, what a
// restart restores, the history's and the panel's limits, which toast a
// full stack lets go, the hover actions, the sender's window and the paused
// and running clocks. Every expected value is written out by hand.
//
// The controls at the end edit a copy of the logic, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.notifications", "NotificationLogic.js");
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
    ["a key twice", stateText({ live: [stored(5, 1)], history: [stored(5, 1)] }), "history.0.key duplicate"]
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

    // Lifetimes: [urgency, sender's timeout, milliseconds shown].
    for (const [urgency, asked, want] of [[U.low, 0, 5000], [U.low, 7000, 7000], [U.normal, 0, 8000], [U.normal, 3000, 8000], [U.normal, 12000, 12000], [U.normal, 90000, 30000], [U.critical, 5000, 0], [U.normal, -1, 8000], [U.normal, NaN, 8000]])
        assert.equal(logic.lifetimeFor(urgency, asked), want, `lifetime of urgency ${urgency} asking ${asked}`);

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
        stored(now - 1000, 5, { deadline: now - 1 })
    ], now);
    same(plan.expired.map(e => e.key), [(now - 9000) + "-1", (now - 1000) + "-5"]);
    same(plan.show.map(e => [e.key, e.deadline === undefined ? null : e.deadline]), [[(now - 3000) + "-2", now + 8000], [(now - 60000) + "-3", null], [(now - 60000) + "-4", now + 8000]]);
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
    ["key clash", "while (taken && taken(keyOf(at, id))) at += 1;", ""],
    ["summary limit", "summary: clip(f.summary, SUMMARY_MAX),", "summary: String(f.summary || \"\"),"],
    ["icon provider path", 'if (s.indexOf(ICON_PROVIDER) === 0 && s.charAt(ICON_PROVIDER.length) === "/") return s.slice(ICON_PROVIDER.length);', ""],
    ["in-process image dropped", '} else if (value.indexOf("image://") === 0) {\n            out[role] = "";', '} else if (false) {\n            out[role] = "";'],
    ["copy once", "if (source !== copy) copies.push({ from: source, to: copy });", "copies.push({ from: source, to: copy });"],
    ["history limit", "if (list.length > limits[lists[l]]) return", "if (false) return"],
    ["entry key identity", 'if (value.key !== keyOf(value.timestamp, value.originalId)) return where + ".key want="', 'if (false) return where + ".key want="'],
    ["duplicate key", 'if (seen[list[i].key]) return { ok: false, error: lists[l] + "." + i + ".key duplicate" };', ""],
    ["unknown state key", 'if (["version", "dnd", "readBefore", "live", "history"].indexOf(keys[k]) === -1) return', "if (false) return"],
    ["deadline outranks arrival", "var over = entry.deadline !== undefined ? now >= entry.deadline : lifetime > 0 && now - entry.timestamp >= lifetime;", "var over = lifetime > 0 && now - entry.timestamp >= lifetime;"],
    ["whole lifetime on restore", "if (lifetime > 0) kept.deadline = now + lifetime;", ""],
    ["history newest first", "merged.sort(function (a, b) { return b.timestamp - a.timestamp; });", ""],
    ["history cut", "return { history: merged.slice(0, HISTORY_MAX), dropped: merged.slice(HISTORY_MAX) };", "return { history: merged, dropped: [] };"],
    ["inbox cutoff", 'var rows = mode === "inbox" ? history.filter(function (e) { return e.timestamp > readBefore; }) : history.slice();', "var rows = history.slice();"],
    ["panel limit", "return rows.slice(0, PANEL_ROWS_MAX);", "return rows;"],
    ["evict non-critical first", "if (rows[i].urgency !== URGENCY.critical) return rows[i].key;", ""],
    ["Show without actions", 'if (list.length === 0 && canFocus) list.push({ id: "focus", label: "Show" });', ""],
    ["charge a stopping clock", "next[keys[i]] = { remaining: Math.max(0, c.remaining - (now - c.since)), since: null };", "next[keys[i]] = { remaining: c.remaining, since: null };"],
    ["paused clocks wait", "if (c.since === null) continue;", ""]
];

const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "notifications-logic-control-"));
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
console.log(`test-notifications-logic: ok bodies=${BODIES.length} states=${STATE_REFUSED.length} controls=${CONTROLS.length}`);
