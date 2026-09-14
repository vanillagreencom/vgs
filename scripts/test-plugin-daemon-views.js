#!/usr/bin/env node

// A bar widget is created once per screen, so a plugin that fetches keeps the fetch in its
// daemon surface and the widget only reads it. This suite replays the link's hold on the
// daemon, which decides whether the daemon polls, and reads each fetching plugin's source for
// the split. The rows list the plugins it covers.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGINS = path.join(repoRoot, "config", "vshell", "plugins");
const LINK = path.join(repoRoot, "quickshell", "vshell", "Modules", "Plugins", "PluginDaemonLink.qml");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

const { syncHold, dropHold } = evaluateMarked(
    fs.readFileSync(LINK, "utf8"), "DAEMON HOLD", ["syncHold", "dropHold"], "PluginDaemonLink.qml");

// A stand-in for PluginDaemonComponent's count. The engine nulls a link's `_held` when the
// held instance is destroyed; the "destroy" step does the same, and a destroyed stand-in
// refuses every later call.
function fakeDaemon() {
    return {
        viewers: 0,
        // Every claim and release. A release and re-claim of the same instance nets zero but
        // turns `watched` off and on, which stops and restarts a daemon's poll.
        calls: 0,
        destroyed: false,
        claimView() {
            assert.ok(!this.destroyed, "a link claimed a destroyed daemon");
            this.calls += 1;
            this.viewers += 1;
        },
        releaseView() {
            assert.ok(!this.destroyed, "a link called into a destroyed daemon");
            assert.ok(this.viewers > 0, "a link released a daemon it never claimed");
            this.calls += 1;
            this.viewers -= 1;
        }
    };
}

test("a link counts once on the daemon it watches, and moves or drops that count as its inputs change", () => {
    // [why, steps, [viewers, calls] on the first daemon, [viewers, calls] on the second]
    for (const [why, steps, expectFirst, expectSecond] of [
        ["a watching link claims the daemon once it registers, however often it re-syncs",
            ["register:first", "sync", "sync"], [1, 1], [0, 0]],
        ["a link that is not watching holds nothing", ["unwatch", "register:first", "sync"], [0, 0], [0, 0]],
        ["unwatching releases the claim and watching again restores exactly one",
            ["register:first", "sync", "unwatch", "sync", "watch", "sync"], [1, 3], [0, 0]],
        // The destroyed instance keeps the count it died with; only the new one's count matters.
        ["a reload moves the claim to the new instance and never calls into the destroyed one",
            ["register:first", "sync", "destroy:first", "register:second", "sync"], [1, 1], [1, 1]],
        ["a daemon replaced while still alive is released before the new one is claimed",
            ["register:first", "sync", "register:second", "sync"], [0, 2], [1, 1]],
        ["a destroyed link releases its claim", ["register:first", "sync", "drop"], [0, 2], [0, 0]],
        ["a destroyed link that held nothing releases nothing",
            ["unwatch", "register:first", "sync", "drop"], [0, 0], [0, 0]]
    ]) {
        const daemons = { first: fakeDaemon(), second: fakeDaemon() };
        const link = { watching: true, daemon: null, _held: null };
        for (const step of steps) {
            const [verb, name] = step.split(":");
            switch (verb) {
            case "register": link.daemon = daemons[name]; break;
            case "destroy":
                if (link._held === daemons[name]) link._held = null;
                link.daemon = null;
                break;
            case "watch": link.watching = true; break;
            case "unwatch": link.watching = false; break;
            case "sync": syncHold(link); break;
            case "drop": dropHold(link); break;
            default: assert.fail(`unknown replay step ${step}`);
            }
        }
        assert.deepEqual(
            [[daemons.first.viewers, daemons.first.calls], [daemons.second.viewers, daemons.second.calls]],
            [expectFirst, expectSecond], why);
    }
});

// [plugin, widget file, daemon file, [token, why] pairs the daemon must keep to poll only while watched]
const ROWS = [
    ["aiUsage", "AiUsageWidget.qml", "AiUsageDaemon.qml", [
        ["running: channels.count > 0 && root.watched",
            "the poll timer runs only while a bar shows the widget"]]],
    ["mercury", "MercuryWidget.qml", "MercuryDaemon.qml", [
        ["onTriggered: { if (root.watched) root.refresh(); }",
            "a poll that comes due with no pill on screen fetches nothing"],
        ["if (root.watched) root.refreshIfStale(); else pollTimer.stop();",
            "and the poll stops when the last pill leaves the screen"]]]
];

test("each fetching plugin polls from its daemon, and its per-screen widget only reads it", () => {
    for (const [plugin, widgetFile, daemonFile, gated] of ROWS) {
        const dir = path.join(PLUGINS, plugin);
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "plugin.json"), "utf8"));
        assert.deepEqual(manifest.components, { widget: "./" + widgetFile, daemon: "./" + daemonFile },
            `${plugin} declares its widget and its daemon surfaces, so the shell creates one daemon`);

        const widget = qmlSource(fs.readFileSync(path.join(dir, widgetFile), "utf8"), widgetFile);
        const widgetCode = widget.stripComments(fs.readFileSync(path.join(dir, widgetFile), "utf8"));
        assert.ok(!/\b(Process|Timer)\s*\{|\bproperty\s+(Process|Timer)\b/.test(widgetCode),
            `${widgetFile} is created once per screen and must own no Timer or Process`);
        widget.requires(widget.blockFrom(widget.indexOf("PluginDaemonLink {"), "the daemon link"),
            `${widgetFile}'s PluginDaemonLink`, [
                ["pluginService: root.pluginService", "the link finds the daemon through the plugin service"],
                ["pluginId: root.pluginId", "under this widget's own plugin id"]]);

        const daemonText = fs.readFileSync(path.join(dir, daemonFile), "utf8");
        const daemon = qmlSource(daemonText, daemonFile);
        assert.ok(/^PluginDaemonComponent \{/m.test(daemon.stripComments(daemonText)),
            `${daemonFile} is a PluginDaemonComponent, which is what counts the links`);
        daemon.requires(daemonText, daemonFile, gated);
    }
});
