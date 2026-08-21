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
    // reported as a fact about the user's themes. A POPULATED source with zero
    // visible entries is tested first: that can only be the filter, and the
    // failure flag outranking it made a filter miss report a read failure over
    // a list already on screen. The detail comes from `blueprintsLoadError`,
    // which only the blueprint read writes — `lastError` is a shared slot every
    // command overwrites, so it can name a different command's failure, or
    // blank out while the surface is up.
    emptyText: {
        if (root.items.length > 0)
            return I18n.tr("No themes match");
        if (VGSThemeService.blueprintsLoadFailed)
            return I18n.tr("Could not read the installed themes") + (VGSThemeService.blueprintsLoadError ? "\n" + VGSThemeService.blueprintsLoadError : "");
        return I18n.tr("No themes installed");
    }

    // A failed refresh over a list that is still on screen: keep it browsable
    // and say it may be stale, rather than discarding a working list or passing
    // it off as fresh.
    staleNotice: VGSThemeService.blueprintsLoadFailed ? I18n.tr("Could not refresh — showing the last known theme list") : ""

    readonly property string activeTheme: (VGSThemeService.currentTheme || {}).name || ""

    activeKey: root.activeTheme
    // What Enter actually needs is an apply not already running. `busy` counts
    // every non-background command, so it blocks on a restyle started from a
    // settings tab and does not block on this switcher's own background reads.
    canApply: !applyReporter.anyApplyInFlight

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

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS theme error")
    }

    onApplied: item => applyReporter.track(VGSThemeService.applyBlueprint(item.key))
}
