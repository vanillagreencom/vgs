pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Services

// Manages keyboard focus policy for popouts, modals, and Hyprland focus grabs
Singleton {
    id: root

    function keyboardFocus(active, customFocus) {
        if (PopoutManager.screenshotActive)
            return WlrKeyboardFocus.None;
        if (customFocus !== null && customFocus !== undefined)
            return customFocus;
        if (!active)
            return WlrKeyboardFocus.None;
        if (CompositorService.useHyprlandFocusGrab)
            return WlrKeyboardFocus.OnDemand;
        return WlrKeyboardFocus.Exclusive;
    }

    function wantsGrab(active, customFocus) {
        return CompositorService.useHyprlandFocusGrab && keyboardFocus(active, customFocus) === WlrKeyboardFocus.OnDemand;
    }

    function captureActiveToplevel() {
        return ToplevelManager.activeToplevel;
    }

    function restoreToplevel(toplevel) {
        if (!toplevel)
            return null;
        // Only skip restoration when the user demonstrably focused a different
        // toplevel while the grab was held; if activeToplevel is unchanged (or
        // null), the seat's keyboard focus may still be stale from the layer
        // surface committing keyboardFocus=None, and activate() must run even
        // though Hyprland already reports this window as active.
        const current = ToplevelManager.activeToplevel;
        if (current && current !== toplevel)
            return null;
        Qt.callLater(() => {
            // The toplevel can close during the deferral; activate() on a
            // destroyed wrapper throws.
            if (ToplevelManager.toplevels.values.includes(toplevel)) {
                toplevel.activate();
                _restoreRetryTarget = toplevel;
                _restoreRetryTimer.restart();
            }
        });
        return null;
    }

    // The single activate() occasionally races surface teardown and loses;
    // verify once after it settles and re-activate if focus is still stale.
    // Never re-activates when the user focused a different toplevel meanwhile.
    property var _restoreRetryTarget: null
    property Timer _restoreRetryTimer: Timer {
        interval: 150
        repeat: false
        onTriggered: {
            const target = root._restoreRetryTarget;
            root._restoreRetryTarget = null;
            if (!target || !ToplevelManager.toplevels.values.includes(target))
                return;
            const current = ToplevelManager.activeToplevel;
            if (current && current !== target)
                return;
            target.activate();
        }
    }

    property list<var> barWindows: []

    function registerBarWindow(window) {
        if (!window || barWindows.indexOf(window) !== -1)
            return;
        barWindows = barWindows.concat([window]);
    }

    function unregisterBarWindow(window) {
        const idx = barWindows.indexOf(window);
        if (idx === -1)
            return;
        const next = barWindows.slice();
        next.splice(idx, 1);
        barWindows = next;
    }

    // Picks the best registered bar to anchor an in-process popout to: prefer the
    // bar on the focused screen, and (when refPropertyName is given) one exposing
    // that ref (e.g. "clockButtonRef" for the dash trigger). Lets components
    // without shell-root scope (e.g. the Settings modal) open the dash the same
    // way the bar does, instead of shelling out to `qs ipc`.
    function getPreferredBar(refPropertyName) {
        if (barWindows.length === 0)
            return null;
        const focusedScreenName = BarWidgetService.getFocusedScreenName();
        let currentBar = null;
        for (let i = 0; i < barWindows.length; i++) {
            const bar = barWindows[i];
            if (!bar)
                continue;
            if (refPropertyName && !bar[refPropertyName])
                continue;
            currentBar = bar;
            if (focusedScreenName && bar.screenName === focusedScreenName)
                break;
        }
        return currentBar;
    }
}
