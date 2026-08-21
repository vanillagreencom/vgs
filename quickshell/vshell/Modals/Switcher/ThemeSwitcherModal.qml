pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Full-screen theme switcher (`vshell ipc call theme-switcher open`).
//
// Source is `VGSThemeService.blueprints` — every INSTALLED theme, built-in or
// user-generated, with the preview path already resolved (cached screenshot →
// committed `preview.png`). `VGSThemeCatalogService` is the download catalog and
// is deliberately not used here: it lists themes that are not installed and
// omits user-generated ones, neither of which belongs in a switcher.
FullScreenSwitcher {
    id: root

    headerTitle: I18n.tr("Theme")
    headerIcon: "palette"
    filterable: true
    filterPlaceholder: I18n.tr("Filter themes...")
    layerNamespace: "vshell:theme-switcher"

    // A failed `theme list` leaves `blueprints` empty, which must not be
    // reported as a fact about the user's themes, and "no match" is only true
    // when a filter is actually on.
    emptyText: {
        if (VGSThemeService.blueprintsLoadFailed)
            return I18n.tr("Could not read the installed themes") + (VGSThemeService.lastError ? "\n" + VGSThemeService.lastError : "");
        if (root.filterQuery !== "")
            return I18n.tr("No themes match");
        return I18n.tr("No themes installed");
    }

    readonly property string activeTheme: (VGSThemeService.currentTheme || {}).name || ""

    activeKey: root.activeTheme
    // show() fires counted helper commands, so `busy` is true for the round trip
    // right after the surface appears — exactly when Enter gets pressed.
    canApply: !VGSThemeService.busy

    items: (VGSThemeService.blueprints || []).filter(bp => !!bp.name).map(bp => ({
                image: bp.preview || "",
                label: bp.name,
                badge: bp.name === root.activeTheme ? I18n.tr("Active") : "",
                key: bp.name
            }))

    function show() {
        VGSThemeService.refresh();
        // Generated themes have no committed preview.png; render the missing
        // ones in the background so the switcher is not a run of blank frames.
        VGSThemeService.generateMissingPreviews();
        open();
    }

    // Driven from a keybind there is no settings tab loaded to report a failed
    // apply, so the switcher reports its own. Latched to the apply it started,
    // and silent on success (the desktop shows it) so an open Themes tab does
    // not double-toast.
    property bool applyPending: false

    onApplied: item => {
        root.applyPending = true;
        VGSThemeService.applyBlueprint(item.key);
    }

    Connections {
        target: VGSThemeService
        function onApplyCompleted(success, message) {
            if (!root.applyPending)
                return;
            root.applyPending = false;
            if (!success)
                ToastService.showError(I18n.tr("VGS theme error"), message);
        }
    }
}
