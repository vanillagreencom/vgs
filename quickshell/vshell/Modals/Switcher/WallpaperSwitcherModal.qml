pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Full-screen wallpaper switcher (`vshell ipc call wallpaper open`).
//
// Scope is the active theme's `backgrounds/` set only — the same list the dash's
// Wallpapers tab shows in "theme" mode. The user's own wallpaper folder stays a
// dash/settings concern; this surface is the theme's own set at full size.
FullScreenSwitcher {
    id: root

    headerTitle: I18n.tr("Wallpaper")
    headerIcon: "wallpaper"
    filterable: false
    emptyText: I18n.tr("This theme has no wallpapers")
    layerNamespace: "vshell:wallpaper-switcher"

    readonly property var wallpaperEntries: VGSThemeService.themeWallpapers || []

    items: root.wallpaperEntries.map(entry => ({
                image: entry.path,
                label: entry.file,
                badge: entry.default ? I18n.tr("Default") : "",
                key: entry.path
            }))

    function show() {
        VGSThemeService.refreshWallpapers();
        open();
    }

    onOpened: selectActive()

    // Land on the wallpaper already in use so paging starts from where the
    // desktop is, not from the top of the list.
    function selectActive() {
        const active = VGSThemeService.selectedWallpaper || "";
        const list = root.items || [];
        for (let i = 0; i < list.length; i++) {
            if (list[i].key === active) {
                root.currentIndex = i;
                return;
            }
        }
        root.currentIndex = 0;
    }

    Connections {
        target: VGSThemeService
        function onWallpapersLoaded() {
            if (root.shouldBeVisible)
                root.selectActive();
        }
    }

    onApplied: item => {
        if (VGSThemeService.busy)
            return;
        VGSThemeService.setWallpaper(item.key);
    }
}
