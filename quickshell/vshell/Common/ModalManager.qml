pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick

Singleton {
    id: modalManager

    signal closeAllModalsExcept(var excludedModal)
    signal modalChanged

    property var currentModalsByScreen: ({})

    // The full-screen switchers are declared once in VGS.qml. Surfaces with no
    // shell-root scope reach them through here — the Settings window's Browse
    // buttons — rather than shelling out to `vshell ipc`, which is the same
    // escape hatch KeyboardFocus.getPreferredBar() is for the bar.
    property var switchers: ({})

    function registerSwitcher(id, modal) {
        switchers[id] = modal;
    }

    // False when nothing is registered under `id`, so a caller can say so
    // rather than appearing to work. `show()` is the switcher's own entry
    // point: it dispatches the list read as well as opening the surface.
    function showSwitcher(id) {
        const modal = switchers[id];
        if (!modal || typeof modal.show !== "function")
            return false;
        modal.show();
        return true;
    }

    function openModal(modal) {
        PopoutManager.screenshotActive = false;
        const screenName = modal.effectiveScreen?.name ?? "unknown";
        currentModalsByScreen[screenName] = modal;
        modalChanged();
        Qt.callLater(() => {
            if (!modal.allowStacking)
                closeAllModalsExcept(modal);
            if (!modal.keepPopoutsOpen)
                PopoutManager.closeAllPopouts();
            TrayMenuManager.closeAllMenus();
        });
    }

    function isCurrentModal(modal, screenName) {
        const name = screenName || modal?.effectiveScreen?.name || "unknown";
        return currentModalsByScreen[name] === modal;
    }

    function closeModal(modal) {
        const screenName = modal.effectiveScreen?.name ?? "unknown";
        if (currentModalsByScreen[screenName] === modal) {
            delete currentModalsByScreen[screenName];
            modalChanged();
        }
    }
}
