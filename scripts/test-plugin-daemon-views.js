#!/usr/bin/env node

// A bar widget is created once per screen, so a plugin that fetches or polls keeps that work in
// its daemon surface and the widget only reads it. This suite replays the link's hold on the
// daemon against the daemon's own count, which decides whether the daemon polls; reads the
// wiring that connects the link, the count and the shell's daemon model; and reads each such
// plugin's source for the split. The rows list the plugins it covers.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGINS = path.join(repoRoot, "config", "vshell", "plugins");
const MODULES = path.join(repoRoot, "quickshell", "vshell", "Modules", "Plugins");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

const { syncHold, dropHold } = evaluateMarked(
    fs.readFileSync(path.join(MODULES, "PluginDaemonLink.qml"), "utf8"), "DAEMON HOLD",
    ["syncHold", "dropHold"], "PluginDaemonLink.qml");
const componentText = fs.readFileSync(path.join(MODULES, "PluginDaemonComponent.qml"), "utf8");
const { claim, release, isWatched } = evaluateMarked(componentText, "DAEMON COUNT",
    ["claim", "release", "isWatched"], "PluginDaemonComponent.qml");

// A daemon counted by PluginDaemonComponent's own claim and release. The engine nulls a link's
// `_held` when the held instance is destroyed; the "destroy" step does the same, and a
// destroyed daemon refuses every later call.
function countedDaemon() {
    return {
        viewers: 0,
        // Every claim and release. A release and re-claim of the same instance nets zero but
        // turns `watched` off and on, which stops and restarts a daemon's poll.
        calls: 0,
        destroyed: false,
        claimView() {
            assert.ok(!this.destroyed, "a link claimed a destroyed daemon");
            this.calls += 1;
            claim(this);
        },
        releaseView() {
            assert.ok(!this.destroyed, "a link called into a destroyed daemon");
            this.calls += 1;
            assert.equal(release(this), true, "a link released a daemon it never claimed");
        }
    };
}

test("a link counts once on the daemon it watches, and moves or drops that count as its inputs change", () => {
    // [why, steps, [viewers, calls, watched] on the first daemon, the same on the second]
    for (const [why, steps, expectFirst, expectSecond] of [
        ["a watching link claims the daemon once it registers, however often it re-syncs",
            ["register:first", "sync", "sync"], [1, 1, true], [0, 0, false]],
        ["a link that is not watching holds nothing",
            ["unwatch", "register:first", "sync"], [0, 0, false], [0, 0, false]],
        ["unwatching releases the claim and watching again restores exactly one",
            ["register:first", "sync", "unwatch", "sync", "watch", "sync"], [1, 3, true], [0, 0, false]],
        // The destroyed instance keeps the count it died with; only the new one's count matters.
        ["a reload moves the claim to the new instance and never calls into the destroyed one",
            ["register:first", "sync", "destroy:first", "register:second", "sync"], [1, 1, true], [1, 1, true]],
        ["a daemon replaced while still alive is released before the new one is claimed",
            ["register:first", "sync", "register:second", "sync"], [0, 2, false], [1, 1, true]],
        ["a destroyed link releases its claim", ["register:first", "sync", "drop"], [0, 2, false], [0, 0, false]],
        ["a destroyed link that held nothing releases nothing",
            ["unwatch", "register:first", "sync", "drop"], [0, 0, false], [0, 0, false]]
    ]) {
        const daemons = { first: countedDaemon(), second: countedDaemon() };
        const link = { watching: true, daemon: null, _held: null };
        for (const step of steps) {
            const [verb, name] = step.split(":");
            switch (verb) {
            case "register": link.daemon = daemons[name]; break;
            case "destroy":
                if (link._held === daemons[name]) link._held = null;
                daemons[name].destroyed = true;
                link.daemon = null;
                break;
            case "watch": link.watching = true; break;
            case "unwatch": link.watching = false; break;
            case "sync": syncHold(link); break;
            case "drop": dropHold(link); break;
            default: assert.fail(`unknown replay step ${step}`);
            }
        }
        const seen = d => [d.viewers, d.calls, isWatched(d.viewers)];
        assert.deepEqual([seen(daemons.first), seen(daemons.second)], [expectFirst, expectSecond], why);
    }
});

test("the link routes its count through the replayed claim and release, and the shell's daemon Instantiator is a ScriptModel keyed by plugin id", () => {
    const component = qmlSource(componentText, "PluginDaemonComponent.qml");
    const shellText = fs.readFileSync(path.join(repoRoot, "quickshell", "vshell", "VGS.qml"), "utf8");
    const shell = qmlSource(shellText, "VGS.qml");
    const instantiator = shell.blockFrom(
        shell.lastIndexOf("Instantiator {", shell.indexOf("id: daemonPluginInstantiator")), "the daemon Instantiator");
    // [block, where, token, why]
    for (const [block, where, token, why] of [
        [componentText, "PluginDaemonComponent.qml", "readonly property bool watched: root.isWatched(root.viewers)",
            "watched follows the count, so a daemon with no watching link polls nothing"],
        [component.body("claimView"), "claimView()", "root.claim(root);", "a link's claim adds to the count"],
        [component.body("releaseView"), "releaseView()", "if (!root.release(root))",
            "a link's release takes from the count"],
        [instantiator, "the daemon Instantiator",
            "model: ScriptModel { values: Object.keys(PluginService.pluginDaemonComponents) }",
            "a plain array model recreates every daemon, and its fetched state, when any daemon plugin loads"]
    ])
        component.requires(block, where, [[token, why]]);
});

// Every Timer block a file declares, located in code so a Timer named only in a comment
// cannot stand in for one, and a brace inside a string cannot end a block early.
function everyTimer(source) {
    const blocks = [];
    for (let at = source.indexOf("Timer {"); at !== -1; at = source.indexOf("Timer {", at + 1))
        blocks.push(source.blockFrom(at, "a Timer"));
    return blocks;
}

// The timers whose own `running:` binding reads root.watched, by id, read from the file under
// test rather than from a second list here. A timer that gates inside onTriggered instead is
// not one of these.
function watchGatedTimerIds(source) {
    const ids = [];
    for (const raw of everyTimer(source)) {
        const block = source.stripComments(raw);
        const id = /\bid:\s*(\w+)/.exec(block);
        const running = /\brunning:\s*(.*)/.exec(block);
        if (id && running && running[1].includes("root.watched"))
            ids.push(id[1]);
    }
    return ids;
}

// [plugin, widget file, daemon file, [token, why] pairs the daemon must keep to run only while watched]
const ROWS = [
    ["aiUsage", "AiUsageWidget.qml", "AiUsageDaemon.qml", [
        ["running: channels.count > 0 && root.watched",
            "the poll timer runs only while a widget watches"],
        ["onSourcesStampChanged: { if (root.watched) root.refresh(); }",
            "a sources change fetches nothing while no widget watches"]]],
    ["mercury", "MercuryWidget.qml", "MercuryDaemon.qml", [
        ["onTriggered: { if (root.watched) root.refresh(); }",
            "a poll that comes due with no watching widget fetches nothing"],
        ["if (root.watched) { pollTimer.restart(); Qt.callLater(root.catchUp); } else { pollTimer.stop(); }",
            "the first watching widget restarts the poll, which a snapshot too fresh to fetch would never " +
            "restart, and queues the catch-up fetch; the poll stops when the last one stops"],
        ["function invalidate() { root.fetchedAt = 0; Qt.callLater(root.catchUp); }",
            "a settings change marks the figures stale and queues the same catch-up, so at shell " +
            "start the saved key stamp and the first watching widget make one bank API call"],
        ["function catchUp() { if (root.watched) root.refreshIfStale(); }",
            "and the catch-up fetches nothing while no widget watches"]]],
    ["sysUpdate", "SysUpdateWidget.qml", "SysUpdateDaemon.qml", [
        ["running: !root.useBackend && root.watched",
            "the count poll runs only while a widget watches, so a bar whose widget is hidden " +
            "spawns no `vshell update count`"],
        ["if (root.watched) root.manualRefresh();",
            "and the bounded re-check after a detached upgrade spawns nothing when it comes due " +
            "with no watching widget"]]],
    ["sudoToggle", "SudoToggleWidget.qml", "SudoToggleDaemon.qml", [
        ["running: root.watched",
            "the 2.5 s flag poll runs only while a widget watches"],
        ["function probeOnFirstWatch() { if (!root.watched || root._statusProbed) return; " +
            "root._statusProbed = true; root.probeStatus(false); }",
            "and the capability probe runs for the first watching widget, once per shell run, " +
            "rather than once per screen at creation"],
        ["onWatchedChanged: root.probeOnFirstWatch()",
            "which is what arms that probe"]]]
];

test("each fetching plugin polls from its daemon, and its per-screen widget only reads it", () => {
    for (const [plugin, widgetFile, daemonFile, gated] of ROWS) {
        const dir = path.join(PLUGINS, plugin);
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "plugin.json"), "utf8"));
        assert.deepEqual(manifest.components, { widget: "./" + widgetFile, daemon: "./" + daemonFile },
            `${plugin} declares its widget and its daemon surfaces, so the shell creates one daemon`);

        const widget = qmlSource(fs.readFileSync(path.join(dir, widgetFile), "utf8"), widgetFile);
        const widgetCode = widget.stripComments(fs.readFileSync(path.join(dir, widgetFile), "utf8"));
        assert.ok(!/\bProcess\s*\{|\bproperty\s+Process\b/.test(widgetCode),
            `${widgetFile} is created once per screen and must own no Process`);
        // A hover delay started by a pointer on one screen is not the per-monitor defect; a
        // timer that repeats is, and so is one armed at creation. Each Timer the widget keeps
        // declares repeat: false, and no running or triggeredOnStart binding arms one.
        for (const declared of everyTimer(widget))
            widget.requires(declared, `${widgetFile}'s Timer`, [["repeat: false",
                "a per-screen Timer must not repeat, which is the per-monitor poll itself"]]);
        assert.ok(!/\brunning:|\btriggeredOnStart:/.test(widgetCode),
            `${widgetFile} must arm no Timer or Process of its own: running and triggeredOnStart ` +
            "start work on every screen without anyone asking for it");
        widget.requires(widget.blockFrom(widget.indexOf("PluginDaemonLink {"), "the daemon link"),
            `${widgetFile}'s PluginDaemonLink`, [
                ["pluginService: root.pluginService", "the link finds the daemon through the plugin service"],
                ["pluginId: root.pluginId", "under this widget's own plugin id"],
                ["watching: root.effectiveVisible",
                    "and holds it only while the widget's visibility condition shows it"]]);

        const daemonText = fs.readFileSync(path.join(dir, daemonFile), "utf8");
        const daemon = qmlSource(daemonText, daemonFile);
        assert.ok(/^PluginDaemonComponent \{/m.test(daemon.stripComments(daemonText)),
            `${daemonFile} is a PluginDaemonComponent, which is what counts the links`);
        daemon.requires(daemonText, daemonFile, gated);
        // A gate that is a `running:` binding is gone the moment anything assigns that timer's
        // running: QML replaces the binding with the plain value, and the poll then spawns work
        // with nothing watching. The pinned token above still reads as present, so ban the
        // assignment as well.
        const daemonFlat = qmlSource.flat(daemon.stripComments(daemonText));
        for (const id of watchGatedTimerIds(daemon))
            for (const arming of [`${id}.restart()`, `${id}.start()`, `${id}.running =`])
                assert.ok(!daemonFlat.includes(arming),
                    `${daemonFile} must not arm ${id} with ${arming}: its running binding is what ` +
                    "holds the root.watched gate, and an assignment replaces it");
    }
});
