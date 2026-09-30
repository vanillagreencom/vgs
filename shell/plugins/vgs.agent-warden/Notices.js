.pragma library
.import "WardenLogic.js" as WardenLogic
.import "ViewLogic.js" as ViewLogic

// The Agent Warden plugin's notices, pure so
// scripts/test-agent-warden-notices.js runs them under node: which episodes
// a status holds, which of them are new, what each new one says, and the
// notify-send argv that sends it.
//
// An episode is a condition that opens and later clears, keyed
// `<kind>:<scope>` as the warden keys its own
// (https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden.md#notifications).
// The service remembers the keys of the open episodes; an episode is sent
// once when it opens and again only after it has cleared and opened again.
// A key clears only on evidence: a fresh status that no longer holds it. A
// status that cannot tell, such as one with no lane listing or a stale
// one, keeps what it cannot judge.
//
// The rules are docs/architecture/agent-warden.md § Notifications. The
// words carry numbers from status.json and the figures, names and lists
// written as the flyout writes them (ViewLogic.js). No text names a
// process id or a scope unit.

// The `notify` setting's values, least first: each sends what the one
// before it sends and more.
var MODES = ["off", "problems", "everything"];
// The most episode keys the service remembers. A new episode that finds
// them all in use is neither sent nor remembered, so it is tried again on
// the next status and never sent twice.
var MAX_EPISODES = 64;
// How often the service touches the warden's heartbeat file. The warden
// leaves every notice to the plugin while the file is less than 120 s old.
var HEARTBEAT_MS = 60000;
// The most notify-send runs that wait for a press on Open vsys at once;
// notify-send waits for the notice to close when it offers an action. A
// notice past it is sent without the button.
var MAX_WAITING = 8;
var APP_NAME = "Agent Warden";
// The action notify-send offers, and prints on stdout when it is pressed.
var ACTION = "open";
var ACTION_LABEL = "Open vsys";
// The scope of an episode no single scope owns, and of the warden's own.
var SLICE = "agents.slice";
var WARDEN = "agent-warden";

// Each episode kind: the notify-send urgency or the toast it is sent as,
// the least MODES value that sends it, whether it offers Open vsys, and
// whether the episodes one status opens go out as one notice.
var KINDS = {
    "tasks": { channel: "notify", urgency: "normal", least: "problems", action: true, grouped: false },
    "memory": { channel: "notify", urgency: "normal", least: "problems", action: true, grouped: false },
    "not-moving": { channel: "notify", urgency: "critical", least: "problems", action: true, grouped: false },
    "move-failure": { channel: "notify", urgency: "normal", least: "problems", action: true, grouped: false },
    "reaped": { channel: "notify", urgency: "low", least: "problems", action: false, grouped: true },
    "not-checking": { channel: "notify", urgency: "normal", least: "problems", action: false, grouped: false },
    "moved": { channel: "toast", urgency: null, least: "everything", action: false, grouped: true }
};
// The kinds whose episodes a fresh status judges, which a status that
// cannot be judged keeps.
var ALL_KINDS = Object.keys(KINDS);

// Whether the service owns the notices: while it reads a status document
// (STATUS, WardenLogic.readStatus's answer or the service's absent and
// pending reads) and notify-send is on PATH (MISSING, the plugin's
// requirement commands the last scan did not find). Only then does it
// touch the heartbeat, so a warden this plugin cannot read, or a desktop
// without notify-send, gets the warden's own notices back within 120 s.
// The `notify` setting plays no part: `off` keeps the heartbeat, so the
// warden stays silent as the user asked.
function owns(status, missing) {
    return status.kind === "read" && missing.indexOf("notify-send") === -1;
}

function key(kind, scope) {
    return kind + ":" + scope;
}

function kindOf(k) {
    return k.slice(0, k.indexOf(":"));
}

// An event's scope, or SLICE for an event no single scope owns.
function eventScope(e) {
    return e.scope === null ? SLICE : e.scope;
}

// The recent events of KINDS_READ, one per scope, the newest of each,
// as { scope, event }, oldest scope first.
function latestByScope(doc, kindsRead, now) {
    var events = [];
    kindsRead.forEach(function (kind) { events = events.concat(WardenLogic.recent(doc, kind, now)); });
    events.sort(function (a, b) { return a.id - b.id; });
    var out = [];
    events.forEach(function (e) {
        var scope = eventScope(e);
        var at = out.findIndex(function (row) { return row.scope === scope; });
        if (at !== -1) out.splice(at, 1);
        out.push({ scope: scope, event: e });
    });
    return out;
}

// The episodes FILE, WardenLogic.fileOf's answer, holds at NOW, with
// DETAIL, WardenLogic.derive's answer for them:
//   { open, held }
// `open` lists each open episode as { key, kind, ... } with the numbers
// and names its words need; `held` is { kinds, keys }, the kinds and keys
// the status cannot judge, which the service keeps as they are.
//   tasks, memory   an agent's lane near that ceiling: tool, worktree,
//                   used, limit; scope the lane's unit
//   not-moving      moves wait for memory headroom: memory, max, tools;
//                   scope SLICE
//   move-failure    a recent move of a process tree that failed or left
//                   part behind: partial, tools, interval; scope the
//                   tree's unit
//   reaped          a recent cleanup of leftover work: processes; scope
//                   the leftover unit
//   moved           a recent move back into limits: tools; scope the
//                   tree's unit
//   not-checking    the warden stopped writing: checkedAt; scope WARDEN
function conditionsOf(file, detail, now) {
    var all = { kinds: ALL_KINDS.slice(), keys: [] };
    switch (detail.state) {
    case "not-set-up":
    case "update-warden":
        return { open: [], held: all };
    case "not-checking":
        if (detail.reason !== "stale") return { open: [], held: all };
        return {
            open: [{ key: key("not-checking", WARDEN), kind: "not-checking", checkedAt: detail.checkedAt }],
            held: { kinds: ALL_KINDS.filter(function (k) { return k !== "not-checking"; }), keys: [] }
        };
    case "calm":
    case "working":
    case "look":
    case "problem":
        break;
    default:
        throw new Error("agent-warden: state=" + JSON.stringify(detail.state) + " unknown");
    }
    if (file.kind !== "read") throw new Error("agent-warden: a fresh state from file kind=" + JSON.stringify(file.kind));
    var doc = file.doc;
    var open = [];
    var held = { kinds: [], keys: [] };

    if (doc.lanes === null) {
        held.kinds.push("tasks", "memory");
    } else {
        WardenLogic.agentLanes(doc).forEach(function (lane) {
            var near = WardenLogic.nearOf(lane);
            var reads = {
                tasks: { used: lane.tasks, limit: WardenLogic.numberOrNull(lane.tasksMax) },
                memory: { used: lane.memory, limit: WardenLogic.numberOrNull(lane.memoryHigh) }
            };
            WardenLogic.NEAR_IDS.forEach(function (kind) {
                var k = key(kind, lane.scope);
                if (near.indexOf(kind) !== -1)
                    open.push({ key: k, kind: kind, tool: lane.label.tool, worktree: lane.label.worktree, used: reads[kind].used, limit: reads[kind].limit });
                else if (reads[kind].used === null)
                    held.keys.push(k);
            });
        });
    }

    if (doc.waiting === null) {
        held.kinds.push("not-moving");
    } else if (doc.waiting.length > 0) {
        var slice = doc.slice;
        open.push({
            key: key("not-moving", SLICE), kind: "not-moving",
            memory: slice === null ? null : slice.memory,
            max: slice === null ? null : WardenLogic.numberOrNull(slice.max),
            tools: WardenLogic.unique(doc.waiting.map(function (t) { return t.tool; }))
        });
    }

    latestByScope(doc, ["partial", "failed"], now).forEach(function (row) {
        open.push({ key: key("move-failure", row.scope), kind: "move-failure", partial: row.event.kind === "partial", tools: WardenLogic.toolsOf(doc, [row.event]), interval: doc.interval });
    });
    latestByScope(doc, ["reaped"], now).forEach(function (row) {
        open.push({ key: key("reaped", row.scope), kind: "reaped", processes: row.event.processes });
    });
    latestByScope(doc, ["moved"], now).forEach(function (row) {
        open.push({ key: key("moved", row.scope), kind: "moved", tools: WardenLogic.toolsOf(doc, [row.event]) });
    });
    return { open: open, held: held };
}

function isHeld(held, k) {
    return held.keys.indexOf(k) !== -1 || held.kinds.indexOf(kindOf(k)) !== -1;
}

// One status's step through MEMORY, the keys the service remembers, with
// CONDITIONS, conditionsOf's answer: { memory, opened, dropped }. `memory`
// keeps each remembered key that is still open or held and adds each new
// open one, up to MAX_EPISODES; `opened` lists the new episodes, which are
// the ones to send; `dropped` counts the new ones past the ceiling.
function step(memory, conditions) {
    var openKeys = conditions.open.map(function (e) { return e.key; });
    var next = memory.filter(function (k) { return openKeys.indexOf(k) !== -1 || isHeld(conditions.held, k); });
    var opened = [];
    var dropped = 0;
    conditions.open.forEach(function (e) {
        if (next.indexOf(e.key) !== -1) return;
        if (next.length >= MAX_EPISODES) {
            dropped += 1;
            return;
        }
        next.push(e.key);
        opened.push(e);
    });
    return { memory: next, opened: opened, dropped: dropped };
}

// MEMORY without KEYS: the episodes of a notice that failed to go out, so
// the next status opens them again, as the warden retries a failed send.
function forget(memory, keys) {
    return memory.filter(function (k) { return keys.indexOf(k) === -1; });
}

function sends(kind, mode) {
    var rank = MODES.indexOf(mode);
    if (rank === -1) throw new Error("agent-warden: notify=" + JSON.stringify(mode) + " unknown");
    return rank >= MODES.indexOf(KINDS[kind].least);
}

function kindOfEpisode(e) {
    var kind = KINDS[e.kind];
    if (kind === undefined) throw new Error("agent-warden: episode kind=" + JSON.stringify(e.kind) + " unknown");
    return kind;
}

// The notices for OPENED, step's new episodes, under MODE, one of MODES,
// at NOW; VSYS is whether the last scan found vsys. Each notice is
// { kind, keys, channel, urgency, action, title, body, tone, icon }:
// `keys` the episodes it tells of, `action` whether it offers Open vsys,
// `tone` and `icon` a toast's. A kind KINDS groups goes out as one notice
// after the others, in KINDS order.
function notices(opened, mode, vsys, now) {
    var out = [];
    var groups = {};
    opened.forEach(function (e) {
        var kind = kindOfEpisode(e);
        if (!sends(e.kind, mode)) return;
        if (kind.grouped) {
            if (groups[e.kind] === undefined) groups[e.kind] = [];
            groups[e.kind].push(e);
        } else {
            out.push(notice(e.kind, [e], vsys, now));
        }
    });
    ALL_KINDS.forEach(function (k) {
        if (groups[k] !== undefined) out.push(notice(k, groups[k], vsys, now));
    });
    return out;
}

function notice(kind, episodes, vsys, now) {
    var look = KINDS[kind];
    var words = copy(kind, episodes, vsys, now);
    return {
        kind: kind,
        keys: episodes.map(function (e) { return e.key; }),
        channel: look.channel,
        urgency: look.urgency,
        action: look.action && vsys,
        title: words.title,
        body: words.body,
        tone: look.channel === "toast" ? "accent" : null,
        icon: look.channel === "toast" ? ViewLogic.ITEM_ICONS[kind] : null
    };
}

// Several tools as a sentence names them, or FALLBACK for none.
function toolsOr(tools, fallback) {
    return tools.length > 0 ? ViewLogic.listed(tools) : fallback;
}

// The tools of EPISODES, each once, in order.
function toolsIn(episodes) {
    return WardenLogic.unique(episodes.reduce(function (all, e) { return all.concat(e.tools); }, []));
}

// The title and body of KIND's notice for EPISODES; VSYS is whether the
// sentence pointing at vsys applies.
function copy(kind, episodes, vsys, now) {
    var e = episodes[0];
    var n = episodes.length;
    switch (kind) {
    case "tasks":
        return {
            title: "An agent is starting a lot of processes",
            body: (e.used === null ? ViewLogic.who(e) + " is starting a lot of processes."
                : e.limit === null ? ViewLogic.who(e) + " is running " + ViewLogic.plural(e.used, "process", "processes") + "."
                : ViewLogic.who(e) + " is at " + ViewLogic.grouped(e.used) + " of its " + ViewLogic.grouped(e.limit) + " limit.")
                + " If it's a big build, you can let it finish." + (vsys ? " If not, open vsys to stop it." : "")
        };
    case "memory":
        return {
            title: "An agent is using a lot of memory",
            body: (e.used === null ? ViewLogic.who(e) + " is using a lot of memory." : ViewLogic.who(e) + " is using " + ViewLogic.gb(e.used) + " GB.")
                + (e.limit === null ? "" : " It will be slowed down at " + ViewLogic.gb(e.limit) + " GB so the rest of your computer stays responsive.")
                + (vsys ? " If you don't need it, open vsys to stop it." : "")
        };
    case "not-moving":
        return {
            title: "Agents are close to their memory limit",
            body: (e.memory === null || e.max === null ? "" : "Agents are using " + ViewLogic.gb(e.memory) + " of " + ViewLogic.gb(e.max) + " GB. ")
                + "Agent Warden is holding off moving " + toolsOr(e.tools, "an agent") + " into the agent group until memory frees up. Closing an agent you don't need will help."
        };
    case "move-failure":
        return {
            title: e.partial ? "Couldn't fully move an agent" : "Couldn't move an agent into its limits",
            body: (e.partial ? "Part of " + toolsOr(e.tools, "an agent") : toolsOr(e.tools, "An agent"))
                + " is still running without limits. Agent Warden will try again in " + ViewLogic.plural(e.interval, "second", "seconds") + "."
        };
    case "reaped":
        if (n > 1)
            return {
                title: "Cleaned up after " + ViewLogic.grouped(n) + " finished agents",
                body: ViewLogic.grouped(n) + " finished agents left work running. Agent Warden stopped it. Your other agents weren't affected."
            };
        return {
            title: "Cleaned up after a finished agent",
            body: (e.processes === null ? "An agent had exited but left work running. Agent Warden stopped it."
                : "An agent had exited but left " + ViewLogic.plural(e.processes, "process", "processes") + " running. Agent Warden stopped " + (e.processes === 1 ? "it." : "them."))
                + " Your other agents weren't affected."
        };
    case "moved":
        var tools = toolsIn(episodes);
        return {
            title: "Moved " + (n === 1 ? "an agent back into its limits" : ViewLogic.grouped(n) + " agents back into their limits"),
            body: (tools.length === 0 ? (n === 1 ? "It was" : "They were") : ViewLogic.listed(tools) + (tools.length === 1 ? " was" : " were"))
                + " running without limits. " + (n === 1 ? "It's" : "They're") + " limited now, so your desktop stays responsive."
        };
    case "not-checking":
        return {
            title: "Agent Warden has stopped checking",
            body: "It last checked " + ViewLogic.ago(e.checkedAt, now) + ", so agents aren't being kept within their limits. Open the Agent Warden panel to start it again."
        };
    }
    throw new Error("agent-warden: notice kind=" + JSON.stringify(kind) + " unknown");
}

// The notify-send argv for NOTICE, a `notify` channel notice, with WAITING
// runs already waiting for a press. `--` ends the options, so a title or
// body that starts with a dash stays text.
function argv(notice, waiting) {
    if (notice.channel !== "notify") throw new Error("agent-warden: channel=" + JSON.stringify(notice.channel) + " is not notify-send's");
    var out = ["notify-send", "-a", APP_NAME, "-u", notice.urgency];
    if (offers(notice, waiting)) out.push("-A", ACTION + "=" + ACTION_LABEL);
    return out.concat(["--", notice.title, notice.body]);
}

// Whether NOTICE's run offers Open vsys, and so waits for a press, with
// WAITING runs already waiting.
function offers(notice, waiting) {
    return notice.action && waiting < MAX_WAITING;
}

// The options shell.toasts.show takes for NOTICE, a `toast` notice.
function toast(notice) {
    if (notice.channel !== "toast") throw new Error("agent-warden: channel=" + JSON.stringify(notice.channel) + " is not a toast");
    return { title: notice.title, message: notice.body, tone: notice.tone, icon: notice.icon };
}

// Whether STDOUT, all a notify-send run printed, says Open vsys was
// pressed: notify-send prints the name of the action chosen.
function pressed(stdout) {
    return stdout.trim() === ACTION;
}
