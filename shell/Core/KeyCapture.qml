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
// commit or cancel, the control's destruction, its plugin instance's
// teardown and a newer holder. Hyprland leaves the submap by itself on
// Escape, on the close of the window that entered it and on a timeout; the
// owner reads each submap change from Hyprland's event socket and ends a
// capture whose submap is gone, so the control and Hyprland agree.
Scope {
    id: root

    // The control capturing keys, or null. An object property reads null
    // once its object is destroyed, which ends the capture.
    property Item holder: null
    // `idle`; `entering`, the enter request sent; or `passthrough`, once
    // Hyprland reports the submap current.
    property string phase: "idle"
    // The holder's instance lifetime registration, released when it ends.
    property var release: null
    // The user's own binds from the last read (Logic.userBinds); null
    // before the first read, which the first conflict question starts.
    property var userBinds: null

    onHolderChanged: if (holder === null && phase !== "idle") finish("destroyed")

    // The `capture` member of the `shortcut` capability for one instance.
    function provider(ctx) {
        return {
            get holder() { return root.holder; },
            get passthrough() { return root.phase === "passthrough"; },
            begin: item => root.begin(ctx, item),
            end: (item, reason) => root.end(item, reason),
            keyFor: (key, modifiers) => Logic.capturedKey(key, modifiers),
            conflicts: (key, id, shortcut) => root.conflicts(key, id, shortcut)
        };
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
        phase = "entering";
        Compositor.passthrough("enter");
        readBinds();
        return "ok";
    }

    // ITEM's capture ends for REASON, `commit` or `cancel`; nothing happens
    // for an item that holds nothing.
    function end(item, reason) {
        if (holder === null || item !== holder) return;
        finish(reason);
    }

    // Every end runs here. The leave request goes out unless Hyprland left
    // the submap itself: it resets only the pass-through submap, so a leave
    // that follows an enter still in flight undoes it.
    function finish(reason) {
        const was = phase;
        const registration = release;
        phase = "idle";
        release = null;
        holder = null;
        if (registration !== null) registration();
        if (was !== "idle" && reason !== "compositor") Compositor.passthrough("leave");
        console.info("capture: end=" + reason);
    }

    function submapChanged(name) {
        if (name === Layer.KEY_PASSTHROUGH.submap) {
            if (phase === "entering") phase = "passthrough";
        } else if (phase === "passthrough") {
            finish("compositor");
        }
    }

    function conflicts(key, id, shortcut) {
        if (userBinds === null) Qt.callLater(readBinds);
        return Logic.keyConflicts(key, Registry.hyprlandSections, userBinds === null ? [] : userBinds, id, shortcut);
    }

    function readBinds() {
        if (userBinds === null) userBinds = [];
        Compositor.readBinds(text => {
            if (text === null) return;
            const read = Logic.userBinds(text, Registry.hyprlandSections);
            if (!read.ok) {
                console.error("capture: " + read.error);
                return;
            }
            root.userBinds = read.binds;
        });
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "submap") root.submapChanged(event.data);
            else if (event.name === "configreloaded" && root.userBinds !== null) root.readBinds();
        }
    }
}
