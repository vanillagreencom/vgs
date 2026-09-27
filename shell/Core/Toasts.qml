pragma Singleton
import QtQuick
import Quickshell
import qs.Commons
import "PluginLogic.js" as Logic

// The toast stack: what shows, what waits and the screen it shows on. A
// plugin's `toasts` capability calls `show`, which judges the options,
// hands the lifetime a release and either shows the toast or queues it;
// past the ceilings it throws. Every way a toast ends runs the one
// release: expiry, the user's dismissal, the disposer the plugin holds and
// the instance's teardown. The release is idempotent, stops the timer,
// takes the toast out of whichever list holds it and lets the next one
// in. The screen is the focused one when the first toast shows; when that
// screen goes, the shown toasts return to the front of the queue and show
// again on the next screen, and with no screen every toast waits.
Singleton {
    id: root

    // Shown toasts, oldest first, and the waiting queue: each is
    // { serial, pluginId, title, message, tone, icon, duration, release,
    // timer }. Replaced whole on every change.
    property var visible: []
    property var waiting: []
    property var screen: null
    property int serial: 0

    readonly property Component timerComponent: Component { Timer { repeat: false } }

    Connections {
        target: Quickshell
        function onScreensChanged() { root.settleScreen(); }
    }

    // Keep the screen while it exists; drop it and re-queue the shown
    // toasts when it goes; take the focused screen when one is needed.
    function settleScreen() {
        if (screen !== null && Quickshell.screens.indexOf(screen) === -1) {
            screen = null;
            const shown = visible;
            visible = [];
            for (const entry of shown) stopTimer(entry);
            waiting = shown.concat(waiting);
        }
        if (screen === null && (visible.length > 0 || waiting.length > 0))
            screen = Compositor.focusedScreen();
        promote();
    }

    // Show one toast for the instance `ctx` belongs to; answers the disposer.
    function show(ctx, options) {
        const judged = Logic.toastOptions(options);
        if (!judged.ok) throw new Error("refused: toast=" + judged.error);
        if (visible.length + waiting.length >= Logic.TOAST_VISIBLE_MAX + Logic.TOAST_QUEUE_MAX)
            throw new Error("refused: toasts=full limit=" + (Logic.TOAST_VISIBLE_MAX + Logic.TOAST_QUEUE_MAX));
        serial += 1;
        const entry = Object.assign({ serial: serial, pluginId: ctx.id, release: null, timer: null }, judged.value);
        entry.release = ctx.onDispose(() => root.remove(entry));
        waiting = waiting.concat([entry]);
        settleScreen();
        return entry.release;
    }

    // Move waiting toasts into the free slots while a screen holds them.
    // A toast's timer starts here, so one that waited shows for its whole
    // duration; the theme's duration is read at this moment.
    function promote() {
        if (screen === null) return;
        while (visible.length < Logic.TOAST_VISIBLE_MAX && waiting.length > 0) {
            const entry = waiting[0];
            waiting = waiting.slice(1);
            const duration = entry.duration === null ? Theme.toast.duration : entry.duration;
            if (duration > 0) {
                entry.timer = timerComponent.createObject(root, { interval: duration });
                entry.timer.triggered.connect(() => entry.release());
                entry.timer.start();
            }
            visible = visible.concat([entry]);
        }
    }

    function stopTimer(entry) {
        if (entry.timer === null) return;
        entry.timer.stop();
        entry.timer.destroy();
        entry.timer = null;
    }

    // The one end of a toast, reached through its release handle.
    function remove(entry) {
        stopTimer(entry);
        visible = visible.filter(e => e !== entry);
        waiting = waiting.filter(e => e !== entry);
        if (visible.length === 0 && waiting.length === 0) screen = null;
        promote();
    }

    // Every live toast by plugin, for the lending record.
    function record() {
        return {
            visible: visible.map(e => ({ plugin: e.pluginId, title: e.title, tone: e.tone })),
            waiting: waiting.map(e => ({ plugin: e.pluginId, title: e.title })),
            screen: screen === null ? null : screen.name
        };
    }
}
