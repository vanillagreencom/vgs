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

    // A failed `theme wallpapers` read leaves whatever was already loaded, so an
    // empty list here means the read failed with nothing to fall back on — that
    // is not "this theme has none". The detail is the read's own error, not the
    // shared `lastError` slot — see ThemeSwitcherModal.
    emptyText: VGSThemeService.wallpapersLoadFailed ? I18n.tr("Could not read this theme's wallpapers") + (VGSThemeService.wallpapersLoadError ? "\n" + VGSThemeService.wallpapersLoadError : "") : I18n.tr("This theme has no wallpapers")

    // The service owns the wording, because the dash's Wallpapers tab shows the
    // same retained list and the two must not describe it differently. "Could
    // not refresh" was also too weak: after a theme switch whose re-read failed,
    // the list is the PREVIOUS theme's, which the service's text names.
    staleNotice: VGSThemeService.wallpapersStaleNotice

    readonly property var wallpaperEntries: VGSThemeService.themeWallpapers || []

    // Land on the wallpaper already in use so paging starts from where the
    // desktop is, not from the top of the list.
    activeKey: VGSThemeService.selectedWallpaper || ""
    // An apply not already running, not the whole service — see ThemeSwitcherModal.
    canApply: !applyReporter.anyApplyInFlight

    // A pathless entry is the apply id as well as the image: `setWallpaper`
    // refuses it and never answers, so it must not be reachable at all.
    items: root.wallpaperEntries.filter(entry => !!entry.path).map(entry => ({
                image: entry.path,
                label: entry.file,
                badge: entry.default ? I18n.tr("Default") : "",
                key: entry.path
            }))

    function show() {
        VGSThemeService.refreshWallpapers();
        open();
    }

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS wallpaper error")
    }

    onApplied: item => applyReporter.track(VGSThemeService.setWallpaper(item.key))
}
