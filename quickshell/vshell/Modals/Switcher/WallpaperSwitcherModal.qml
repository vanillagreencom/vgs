pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Full-screen wallpaper switcher (`vshell ipc call wallpaper-switcher open`).
//
// Scope is the active theme's `backgrounds/` set only — the same list the dash's
// Wallpapers tab shows in "theme" mode. The user's own wallpaper folder stays a
// dash/settings concern; this surface is the theme's own set at full size.
FullScreenSwitcher {
    id: root

    headerTitle: I18n.tr("Wallpaper")
    headerIcon: "wallpaper"
    filterable: false
    layerNamespace: "vshell:wallpaper-switcher"

    // `refreshWallpapers` clears the list on a helper failure too, so an empty
    // list alone cannot be asserted as "this theme has none".
    emptyText: VGSThemeService.wallpapersLoadFailed ? I18n.tr("Could not read this theme's wallpapers") + (VGSThemeService.lastError ? "\n" + VGSThemeService.lastError : "") : I18n.tr("This theme has no wallpapers")

    readonly property var wallpaperEntries: VGSThemeService.themeWallpapers || []

    // Land on the wallpaper already in use so paging starts from where the
    // desktop is, not from the top of the list.
    activeKey: VGSThemeService.selectedWallpaper || ""
    // `refreshWallpapers` is a counted command: `busy` is true for the round trip
    // right after show(), exactly when Enter gets pressed.
    canApply: !VGSThemeService.busy

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

    // See ThemeSwitcherModal: a keybind-driven failure has no settings tab to
    // report it, and success is silent so an open tab does not double-toast.
    property bool applyPending: false

    onApplied: item => {
        root.applyPending = true;
        VGSThemeService.setWallpaper(item.key);
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
