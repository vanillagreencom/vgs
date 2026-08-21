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
    emptyText: I18n.tr("No themes match")
    layerNamespace: "vshell:theme-switcher"

    readonly property string activeTheme: (VGSThemeService.currentTheme || {}).name || ""

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

    onOpened: selectActive()

    // Start on the theme currently applied.
    function selectActive() {
        const list = root.items || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].key === root.activeTheme) {
                root.currentIndex = i;
                return;
            }
        }
        root.currentIndex = 0;
    }

    Connections {
        target: VGSThemeService
        function onBlueprintsLoaded() {
            // Only while the user has not started filtering: re-seeding the
            // selection under an active query would fight their typing.
            if (root.shouldBeVisible && root.filterQuery === "")
                root.selectActive();
        }
    }

    onApplied: item => {
        if (VGSThemeService.busy)
            return;
        VGSThemeService.applyBlueprint(item.key);
    }
}
