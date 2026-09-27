pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Switch themes from VGSThemeService.blueprints, including user-generated themes.
// Every theme is listed; the pill narrows the list to starred themes.
FullScreenSwitcher {
    id: root

    filterable: true
    layerNamespace: "vshell:theme-switcher"

    // Kept across opens: Starred is a standing choice of which themes to browse, not an apply target.
    property bool starredOnly: false

    // Prioritize filter misses when entries are loaded. Otherwise use the blueprint read's own error, not the shared command error slot.
    emptyText: {
        if (root.items.length > 0)
            return I18n.tr("No themes match");
        if (VGSThemeService.blueprintsLoadFailed)
            return I18n.tr("Could not read the installed themes") + (VGSThemeService.blueprintsLoadError ? "\n" + VGSThemeService.blueprintsLoadError : "");
        if (root.starredOnly && (VGSThemeService.blueprints || []).length > 0)
            return I18n.tr("No starred themes. Star one from the Themes tab in the Dash.");
        return I18n.tr("No themes installed");
    }

    // Keep a retained list browsable and identify it as stale after refresh failure.
    staleNotice: VGSThemeService.blueprintsLoadFailed ? I18n.tr("Could not refresh — showing the last known theme list") : ""

    readonly property string activeTheme: (VGSThemeService.currentTheme || {}).name || ""

    activeKey: root.activeTheme
    // Gate on active applies; service busy also counts unrelated work.
    canApply: !applyReporter.anyApplyInFlight

    // BEGIN THEME LIST DECISION
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-scope.js extracts and executes it.

    // The carousel entries for a theme list. The full-size preview is what the
    // selected frame paints; the 480 px thumbnail stands in only for a theme the
    // helper reports no preview for.
    function themeItems(blueprints, starredOnly) {
        return (blueprints || []).filter(bp => !!bp.name && (!starredOnly || bp.starred === true)).map(bp => ({
                    image: bp.preview || bp.thumbnail || "",
                    label: bp.name,
                    key: bp.name
                }));
    }
    // END THEME LIST DECISION

    items: root.themeItems(VGSThemeService.blueprints, root.starredOnly)

    scopeToggle: starPill
    onScopeFlipRequested: root.starredOnly = !root.starredOnly

    function show() {
        VGSThemeService.refresh();
        open();
    }

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS theme error")
    }

    onApplied: item => applyReporter.track(VGSThemeService.applyBlueprint(item.key, true))

    Component {
        id: starPill

        SwitcherSegmentPill {
            labels: [I18n.tr("All"), I18n.tr("Starred")]
            activeIndex: root.starredOnly ? 1 : 0
            onPicked: root.scopeFlipRequested()
        }
    }
}
