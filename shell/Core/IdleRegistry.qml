import QtQuick
import Quickshell
import Quickshell.Wayland
import "PluginLogic.js" as Logic

// Owns the idle watches across plugin instances: one IdleMonitor per watch,
// through the compositor's ext-idle-notify-v1, respecting idle inhibitors
// such as a playing video's. Each watch belongs to its instance lifetime and
// destroys its monitor with it.
Scope {
    id: root
    // `<plugin id>#<serial>` -> the watch's IdleMonitor, replaced whole on
    // every change.
    property var watches: ({})
    property int serial: 0

    function provider(ctx) {
        return { watch: (seconds, onChange) => root.watch(ctx, seconds, onChange) };
    }

    // idle: `onChange(isIdle)` each time the user has given no input for
    // `seconds` and each time input returns. Returns the disposer.
    function watch(ctx, seconds, onChange) {
        const refusal = Logic.idleWatchRefusal(seconds, onChange);
        if (refusal !== "") throw new Error(refusal);
        const key = ctx.id + "#" + (++serial);
        const monitor = monitorComponent.createObject(root, { timeout: seconds });
        monitor.handler = onChange;
        const next = Object.assign({}, watches);
        next[key] = monitor;
        watches = next;
        return ctx.onDispose(() => {
            const rest = Object.assign({}, root.watches);
            delete rest[key];
            root.watches = rest;
            monitor.destroy();
        });
    }

    // The watches for the lending record: plugin id, timeout and state.
    function record() {
        return Object.keys(watches).sort().map(key => ({ id: key.split("#")[0], timeout: watches[key].timeout, idle: watches[key].isIdle }));
    }

    Component {
        id: monitorComponent
        IdleMonitor {
            property var handler: null
            respectInhibitors: true
            onIsIdleChanged: handler(isIdle)
        }
    }
}
