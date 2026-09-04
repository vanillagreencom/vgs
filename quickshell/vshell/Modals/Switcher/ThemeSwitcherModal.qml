pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Switch installed themes from VGSThemeService.blueprints, including user-generated themes.
// The download catalog is not the installed-theme list.
FullScreenSwitcher {
    id: root

    filterable: true
    layerNamespace: "vshell:theme-switcher"

    // Prioritize filter misses when entries are loaded. Otherwise use the blueprint read's own error, not the shared command error slot.
    emptyText: {
        if (root.items.length > 0)
            return I18n.tr("No themes match");
        if (VGSThemeService.blueprintsLoadFailed)
            return I18n.tr("Could not read the installed themes") + (VGSThemeService.blueprintsLoadError ? "\n" + VGSThemeService.blueprintsLoadError : "");
        return I18n.tr("No themes installed");
    }

    // Keep a retained list browsable and identify it as stale after refresh failure.
    staleNotice: VGSThemeService.blueprintsLoadFailed ? I18n.tr("Could not refresh — showing the last known theme list") : ""

    readonly property string activeTheme: (VGSThemeService.currentTheme || {}).name || ""

    activeKey: root.activeTheme
    // Gate on active applies; service busy also counts unrelated work.
    canApply: !applyReporter.anyApplyInFlight

    items: (VGSThemeService.blueprints || []).filter(bp => !!bp.name).map(bp => ({
                image: bp.preview || "",
                label: bp.name,
                key: bp.name
            }))

    function show() {
        VGSThemeService.refresh();
        // Generated themes have no committed preview.png; render the missing
        // ones in the background so the switcher is not a run of blank frames.
        VGSThemeService.generateMissingPreviews();
        open();
    }

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS theme error")
    }

    onApplied: item => applyReporter.track(VGSThemeService.applyBlueprint(item.key))
}
