import QtQuick
import Quickshell
import Quickshell.Hyprland
import "PluginLogic.js" as Logic
import "HyprlandLayer.js" as Layer

// The one owner of key capture: which control holds the keyboard for a key
// combo, and the Hyprland pass-through submap that lets a combo a bind
// holds reach it (HyprlandLayer.KEY_PASSTHROUGH). A control asks to begin
// and to end, and never dispatches; the owner enters the submap through
// Compositor and leaves it on every end the shell sees: the control's
// commit, cancel or focus loss, the control's destruction, its plugin
// instance's teardown and a newer holder. Hyprland leaves the submap by
// itself on Escape, on the close of the window that entered it, on a
// timeout and when the layer runs again; the owner reads each submap change
// from Hyprland's event socket and ends a capture whose submap is gone, so
// the control and Hyprland agree.
Scope {
    id: root

    // The control capturing keys, or null. An object property reads null
    // once its object is destroyed, which ends the capture.
    property Item holder: null
    // `idle`; `waiting`, a holder whose enter waits for an earlier leave to
    // run; `entering`, the enter request sent; or `passthrough`, once
    // Hyprland reports the submap current.
    property string phase: "idle"
    // Whether the holder's enter was refused or answered with an error:
    // Hyprland's own binds still run, and only keys they leave reach it.
    property bool failed: false
    // Leave requests sent and not yet answered. A begin while one is
    // pending waits to send its enter until every leave was answered:
    // Hyprland posts a request's submap event before it answers the request
    // (Actions::setSubmap, HyprCtl.cpp), so an earlier capture's events come
    // while the new holder waits, and a waiting holder reads none.
    property int leaving: 0
    // Counts begins, so an enter answer for an earlier capture is dropped.
    property int generation: 0
    property real began: 0
    // The last capture that ended, as { item, reason }: `commit`, `cancel`,
    // `tab`, `focus`, `destroyed`, `disposed`, `superseded`, `compositor`,
    // or `timeout` for a compositor end after the layer's timeout.
    property var ended: ({ item: null, reason: "" })
    // The holder's instance lifetime registration, released when it ends.
    property var release: null
    // HyprlandState, the one reader of `hyprctl -j binds`: its
    // `foreignKeys`, the keys something other than the layer binds, null
    // while unread, its `bindsFailure`, and `readBinds()`. `wantsBinds`
    // keeps its reads on while a control captures or an instance that asked
    // a conflict question lives; it reads again after each Hyprland reload,
    // and a question after a failed read asks once more.
    property var bindsSource: null
    property int askers: 0
    readonly property bool capturing: holder !== null
    readonly property bool wantsBinds: capturing || askers > 0
    // Plain state a conflict question writes while a binding reads it, so
    // the write notifies no binding.
    property var bindsRetry: ({ asked: false })

    onHolderChanged: if (holder === null && phase !== "idle") finish("destroyed")

    // The `capture` member of the `shortcut` capability for one instance.
    function provider(ctx) {
        const asking = { started: false };
        return {
            get holder() { return root.holder; },
            get passthrough() { return root.phase === "passthrough"; },
            get failed() { return root.failed; },
            get ended() { return root.ended; },
            timeoutMs: Layer.KEY_PASSTHROUGH.timeoutMs,
            begin: item => root.begin(ctx, item),
            end: (item, reason) => root.end(item, reason),
            keyFor: (key, modifiers) => Logic.capturedKey(key, modifiers),
            conflicts: (key, id, shortcut) => {
                if (!asking.started) {
                    asking.started = true;
                    Qt.callLater(() => root.ask(ctx));
                }
                return root.conflicts(key, id, shortcut);
            }
        };
    }

    // CTX's instance asked who holds a key: the binds stay read until it is
    // torn down.
    function ask(ctx) {
        askers += 1;
        ctx.onDispose(() => { root.askers -= 1; });
    }

    // ITEM takes the keyboard for a combo; a holder already capturing ends
    // first. Answers `ok`.
    function begin(ctx, item) {
        if (item === null || item === undefined)
            throw new Error("refused: capture holder=none");
        if (holder === item) return "ok";
        if (holder !== null) finish("superseded");
        holder = item;
        release = ctx.onDispose(() => root.end(item, "disposed"));
        failed = false;
        generation += 1;
        began = Date.now();
        if (leaving > 0) phase = "waiting";
        else enter();
        return "ok";
    }

    // ITEM's capture ends for REASON, such as `commit`, `cancel` or
    // `focus`; nothing happens for an item that holds nothing.
    function end(item, reason) {
        if (holder === null || item !== holder) return;
        finish(reason);
    }

    function enter() {
        phase = "entering";
        const at = generation;
        const answer = Compositor.passthrough("enter", reply => root.entered(at, reply));
        if (answer !== "ok") entered(at, answer);
    }

    function entered(at, reply) {
        if (at !== generation || holder === null || reply === "ok") return;
        failed = true;
        console.info("capture: enter=failed reply=" + JSON.stringify(reply));
    }

    // Every end runs here. The leave request goes out unless Hyprland left
    // the submap itself or no enter was sent: it resets only the
    // pass-through submap, so a leave that follows an enter still in flight
    // undoes it.
    function finish(reason) {
        const was = phase;
        const item = holder;
        const registration = release;
        ended = { item: item, reason: reason };
        phase = "idle";
        release = null;
        failed = false;
        holder = null;
        if (registration !== null) registration();
        if ((was === "entering" || was === "passthrough") && reason !== "compositor" && reason !== "timeout") leave();
        console.info("capture: end=" + reason);
    }

    function leave() {
        leaving += 1;
        if (Compositor.passthrough("leave", () => root.left()) !== "ok") left();
    }

    function left() {
        leaving -= 1;
        if (leaving === 0 && phase === "waiting") enter();
    }

    function submapChanged(name) {
        if (name === Layer.KEY_PASSTHROUGH.submap) {
            if (phase === "entering") phase = "passthrough";
        } else if (phase === "passthrough") {
            const held = Date.now() - began;
            console.info("capture: compositor submap=" + JSON.stringify(name) + " held_ms=" + held);
            finish(held >= Layer.KEY_PASSTHROUGH.timeoutMs ? "timeout" : "compositor");
        }
    }

    // Who else holds KEY, for the field's hint: Logic.keyConflicts with
    // `binds`, the binds read's state, `unread`, `read` or `failed`, beside it.
    function conflicts(key, id, shortcut) {
        const source = bindsSource;
        const state = source === null || (source.foreignKeys === null && source.bindsFailure === "") ? "unread" : source.bindsFailure !== "" ? "failed" : "read";
        if (state === "failed" && !bindsRetry.asked) {
            bindsRetry.asked = true;
            Qt.callLater(() => source.readBinds());
        } else if (state === "read") {
            bindsRetry.asked = false;
        }
        const found = Logic.keyConflicts(key, Registry.hyprlandSections, state === "read" ? source.foreignKeys : [], id, shortcut);
        return { plugins: found.plugins, user: found.user, binds: state };
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "submap") root.submapChanged(event.data);
        }
    }
}
