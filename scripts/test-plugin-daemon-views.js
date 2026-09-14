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

// The daemon timers whose own `running:` binding reads root.watched, by id, read from the file
// under test. Flattened first, so a binding wrapped across lines still resolves; the value is
// taken up to the next property, not to the end of the line. Every row declares the ids it
// expects, because a loop over an empty result asserts nothing and still reports green.
function watchGatedTimerIds(source) {
    const ids = [];
    for (const { text, q } of source.objectBlocks("Timer")) {
        const flat = qmlSource.flat(q.stripComments(text));
        const id = /\bid:\s*(\w+)/.exec(flat);
        const running = /\brunning:\s*((?:(?!\b[A-Za-z_]\w*\s*:).)*)/.exec(flat);
        if (id && running && running[1].includes("root.watched"))
            ids.push(id[1]);
    }
    return ids;
}

// One row per bundled plugin shipping both a widget and a daemon surface; the test below derives
// that set from the manifests and requires it to equal these ids.
// - widgetTimers: how many Timer blocks the per-screen widget may declare. A hover delay a
//   pointer starts on one screen is not the per-monitor defect; a timer that repeats or arms
//   itself is, so each declared Timer must carry repeat: false and arm nothing.
// - entryPoints: [function, the effect its guard must precede] for each widget function that
//   routes a user action through the daemon. The Instantiator is asynchronous and a reload
//   reopens the same window, so each must report a click that reaches no instance.
// - watchGated: the daemon timers whose running binding holds the root.watched gate.
// - gated: [token, why] the daemon must keep so it runs only while a widget watches.
const ROWS = [
    {
        plugin: "aiUsage", entryPoints: [], widget: "AiUsageWidget.qml", daemon: "AiUsageDaemon.qml",
        widgetTimers: 0, watchGated: ["pollTimer"],
        gated: [
            ["running: channels.count > 0 && root.watched",
                "the poll timer runs only while a widget watches"],
            ["onSourcesStampChanged: { if (root.watched) root.refresh(); }",
                "a sources change fetches nothing while no widget watches"]]
    },
    {
        plugin: "mercury", entryPoints: [], widget: "MercuryWidget.qml", daemon: "MercuryDaemon.qml",
        // mercury gates inside onTriggered rather than in a running binding, so its poll timer
        // is not watch-gated and its own restart() stays legal.
        widgetTimers: 0, watchGated: [],
        gated: [
            ["onTriggered: { if (root.watched) root.refresh(); }",
                "a poll that comes due with no watching widget fetches nothing"],
            ["if (root.watched) { pollTimer.restart(); Qt.callLater(root.catchUp); } else { pollTimer.stop(); }",
                "the first watching widget restarts the poll, which a snapshot too fresh to fetch would never " +
                "restart, and queues the catch-up fetch; the poll stops when the last one stops"],
            ["function invalidate() { root.fetchedAt = 0; Qt.callLater(root.catchUp); }",
                "a settings change marks the figures stale and queues the same catch-up, so at shell " +
                "start the saved key stamp and the first watching widget make one bank API call"],
            ["function catchUp() { if (root.watched) root.refreshIfStale(); }",
                "and the catch-up fetches nothing while no widget watches"]]
    },
    {
        plugin: "sysUpdate", entryPoints: [["launch", "closePopout"], ["manualRefresh", null], ["reviewOrphans", null]], widget: "SysUpdateWidget.qml", daemon: "SysUpdateDaemon.qml",
        widgetTimers: 0, watchGated: ["pollTimer"],
        gated: [
            ["running: !root.useBackend && root.watched",
                "the count poll runs only while a widget watches, so a bar whose widget is hidden " +
                "spawns no `vshell update count`"],
            ["if (root.watched) root.manualRefresh();",
                "and the bounded re-check after a detached upgrade spawns nothing when it comes due " +
                "with no watching widget"],
            ["Loader { active: root.watched sourceComponent: Component { Ref { service: SystemUpdateService } } }",
                "the service ref is held only while a widget watches, so with the widget on no bar " +
                "refCount stays 0 and the backend schedules no checkupdates, paru or mise run"],
            ["target: root.watched ? SystemUpdateService : null",
                "and a backend broadcast rebuilds no package list for a daemon nothing is reading"],
            ["onWatchedChanged: { if (root.watched) root._syncBackendState(); }",
                "while the first watching widget re-reads that state, which the backend path has no " +
                "triggeredOnStart of its own to do"]]
    },
    {
        plugin: "sudoToggle", entryPoints: [["toggle", null]], widget: "SudoToggleWidget.qml", daemon: "SudoToggleDaemon.qml",
        widgetTimers: 1, watchGated: ["pollTimer"],
        gated: [
            ["running: root.watched",
                "the 2.5 s flag poll runs only while a widget watches"],
            ["watchChanges: root.watched", 2,
                "and neither flag file keeps an inotify watch while nothing watches"],
            ["function probeOnFirstWatch() { if (!root.watched || root._statusProbed) return; " +
                "root._statusProbed = true; root.probeStatus(false); }",
                "the capability probe runs for the first watching widget, once per shell run, " +
                "rather than once per screen at creation"],
            ["onWatchedChanged: root.probeOnFirstWatch()",
                "which is what arms that probe"]]
    }
];

test("ROWS covers every bundled plugin that ships both a widget and a daemon surface", () => {
    const declared = fs.readdirSync(PLUGINS).filter(id => {
        const manifest = path.join(PLUGINS, id, "plugin.json");
        if (!fs.existsSync(manifest))
            return false;
        const components = JSON.parse(fs.readFileSync(manifest, "utf8")).components || {};
        return typeof components.widget === "string" && typeof components.daemon === "string";
    });
    assert.deepEqual(declared.sort(), ROWS.map(row => row.plugin).sort(),
        "a bundled plugin declaring both surfaces takes a row here, or it gets no manifest check, " +
        "no widget rule, no watched gate and no arming ban while the architecture doc reads as a " +
        "rule for every plugin that follows the convention");
});

test("each polling plugin runs from its daemon, and its per-screen widget only reads it", () => {
    for (const row of ROWS) {
        const { plugin, entryPoints, widgetTimers, watchGated, gated } = row;
        const widgetFile = row.widget;
        const daemonFile = row.daemon;
        const dir = path.join(PLUGINS, plugin);
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "plugin.json"), "utf8"));
        assert.deepEqual(manifest.components, { widget: "./" + widgetFile, daemon: "./" + daemonFile },
            `${plugin} declares its widget and its daemon surfaces, so the shell creates one daemon`);

        const widget = qmlSource(fs.readFileSync(path.join(dir, widgetFile), "utf8"), widgetFile);
        widget.objectBlocks("Process", 0);
        assert.ok(!/\bproperty\s+(Process|Timer)\b/.test(widget.stripComments(
            fs.readFileSync(path.join(dir, widgetFile), "utf8"))),
            `${widgetFile} is created once per screen and must hold no Process or Timer property`);
        for (const { text } of widget.objectBlocks("Timer", widgetTimers))
            widget.requires(text, `${widgetFile}'s Timer`, [
                ["repeat: false", "a per-screen Timer must not repeat, which is the per-monitor poll itself"],
                ["running:", "and must not arm itself on every screen", 0],
                ["triggeredOnStart:", "nor fire once on every screen at creation", 0]]);
        // A dropped action is never silent: with no daemon the sysUpdate popout reads
        // "Checking…" forever and the sudo pill reads unavailable, so nothing else tells the
        // user the click went nowhere. The guard also runs before the action's own visible
        // effect, or the popout closes as though the upgrade had been accepted.
        for (const [fn, effect] of entryPoints) {
            const body = widget.body(fn);
            const guard = body.indexOf("if (!root.daemon)");
            assert.notEqual(guard, -1, `${widgetFile}'s ${fn}() must guard on a missing daemon instance`);
            const stripped = widget.stripComments(body);
            assert.ok(stripped.indexOf("root.reportNoDaemon(") > guard,
                `${widgetFile}'s ${fn}() must report the dropped action inside that guard, not return in silence`);
            assert.ok(guard < stripped.indexOf("root.daemon."),
                `${widgetFile}'s ${fn}() must guard before it calls into the daemon`);
            if (effect !== null)
                assert.ok(guard < stripped.indexOf(effect),
                    `${widgetFile}'s ${fn}() must guard before ${effect}, or a click that reaches no ` +
                    "daemon still has a visible effect and reads as accepted");
        }

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
        daemon.requires(daemonText, daemonFile,
            gated.map(([token, a, b]) => typeof a === "number" ? [token, b, a] : [token, a]));

        // A gate that is a `running:` binding is not removed by restart() or start(): those set
        // running past the gate, and it stays set until that binding's expression next changes
        // value, which with nothing watching may be never. Only `running =` drops the binding
        // outright. The pinned token above still reads as present through all three, so ban them.
        assert.deepEqual(watchGatedTimerIds(daemon), watchGated,
            `${daemonFile}'s watch-gated timers must be exactly the ids the row declares, or the ` +
            "arming ban below runs over an empty list and asserts nothing");
        const daemonCode = daemon.stripComments(daemonText);
        for (const id of watchGated)
            for (const arming of [new RegExp(`\\b${id}\\.(restart|start)\\s*\\(`), new RegExp(`\\b${id}\\.running\\s*=[^=]`)])
                assert.ok(!arming.test(daemonCode),
                    `${daemonFile} must not arm ${id} with ${arming.source}: its running binding is ` +
                    "what holds the root.watched gate");
    }
});
