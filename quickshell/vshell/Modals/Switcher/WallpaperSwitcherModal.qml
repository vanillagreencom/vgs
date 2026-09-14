pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Switch wallpapers from the active theme's set (Theme) or from the wallpaper folder and every installed theme (All).
// Under Theme, a catalog theme whose imagery is missing or outdated offers one card that downloads or updates it.
// With several monitors, choose all outputs or this output; each open starts with all outputs selected.
FullScreenSwitcher {
    id: root

    filterable: false

    showLabels: root.source === "all"
    layerNamespace: "vshell:wallpaper-switcher"

    // The service owns the empty and retained-list wording for each source, so this switcher and Dash cannot disagree.
    emptyText: VGSThemeService.emptyTextFor(root.source)
    staleNotice: VGSThemeService.staleNoticeFor(root.source)

    readonly property var wallpaperEntries: VGSThemeService.themeWallpapers || []
    readonly property int screenCount: (Quickshell.screens || []).length
    // Reset apply scope to all monitors on each open so a previous local choice cannot silently carry over.
    property bool applyToAllMonitors: true
    // "theme" or "all". Each open starts from SettingsData.wallpaperSource; the Dash tab reads it only when it loads.
    property string source: "theme"
    readonly property string appliedTheme: (VGSThemeService.currentTheme || {}).name || ""
    readonly property var imageryCard: VGSThemeCatalogService.imageryCardFor(root.appliedTheme)

    // BEGIN WALLPAPER SCOPE DECISION
    // Scope decisions take explicit inputs rather than reading QML state.
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-scope.js extracts and executes it.

    // Whether there is a scope to choose. One monitor leaves nothing to
    // point at: the pill hides and Tab stays on paging.
    function scopeChoiceExists(screenCount) {
        return screenCount > 1;
    }

    // Seed this-monitor scope from its current wallpaper. All-monitor scope has a current key only when outputs agree.
    function scopeSeedKey(allMonitors, shownEverywhere, shownHere, pendingClaim) {
        if (!allMonitors)
            return shownHere || pendingClaim || "";
        const shown = shownEverywhere || [];
        for (let i = 1; i < shown.length; i++) {
            if (shown[i] !== shown[0])
                return "";
        }
        return (shown.length > 0 ? shown[0] : "") || pendingClaim || "";
    }

    // Route all-monitor applies through the service. A single remaining monitor also uses that path if scope state is stale.
    function applyRoute(allMonitors, screenCount) {
        if (allMonitors || !scopeChoiceExists(screenCount))
            return "service";
        return "screen";
    }
    // END WALLPAPER SCOPE DECISION

    // BEGIN WALLPAPER SOURCE DECISION
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-source.js extracts and executes it.

    // What activating an entry does. A card never reaches set-wallpaper: "fetch" hands it to the catalog, which
    // starts nothing for a card whose command already runs.
    function activationRoute(item) {
        return item.card ? "fetch" : "wallpaper";
    }
    // END WALLPAPER SOURCE DECISION

    // Read current wallpapers from SessionData because cycling can bypass the theme service.
    // Use the service's optimistic value only as fallback; scopeSeedKey selects the relevant monitor answers.
    activeKey: {
        const screenName = root.effectiveScreen ? String(root.effectiveScreen.name || "") : "";
        const shown = screenName ? SessionData.getMonitorWallpaper(screenName) : SessionData.wallpaperPath;
        const everywhere = (Quickshell.screens || []).map(screen => SessionData.getMonitorWallpaper(screen.name));
        return root.scopeSeedKey(root.applyToAllMonitors, everywhere, shown, VGSThemeService.selectedWallpaper || "");
    }
    // Block both routes during service apply: its eventual all-monitor write could overwrite a local assignment.
    canApply: !applyReporter.anyApplyInFlight

    // Filter pathless entries because an empty apply id is refused without a completion reply.
    items: {
        const all = root.source === "all";
        const wallpapers = (all ? (VGSThemeService.allWallpapers || []) : root.wallpaperEntries).filter(entry => !!entry.path).map(entry => ({
                    image: entry.path,
                    thumb: entry.thumb || "",
                    label: all ? entry.file + " · " + (entry.source === "folder" ? I18n.tr("My folder") : entry.source) : entry.file,
                    key: entry.path,
                    marked: all && VGSThemeService.inThemeSet(entry, root.appliedTheme, root.wallpaperEntries, VGSThemeService.themeWallpapersTheme)
                }));
        if (all)
            return wallpapers;
        return VGSThemeCatalogService.themeRail(wallpapers, root.imageryCard).map(item => item.card ? Object.assign({
                image: "",
                label: VGSThemeCatalogService.imageryCardLabel(root.appliedTheme, item.card)
            }, item) : item);
    }

    scopeToggle: root.scopeChoiceExists(root.screenCount) ? scopePill : null
    onScopeFlipRequested: root.applyToAllMonitors = !root.applyToAllMonitors
    sourceToggle: sourcePill
    itemMenu: root.source === "all" && root.appliedTheme ? addToThemeMenu : null

    // The All view's check marks read the theme's set, so every open refreshes it.
    function show() {
        VGSThemeService.refreshWallpapers();
        open();
    }

    // Read only what the chosen view shows: the All list, or the catalog the Theme view's card comes from.
    function refreshSource() {
        if (root.source === "all")
            VGSThemeService.refreshAllWallpapers();
        else
            VGSThemeCatalogService.refresh();
    }

    // Verify the single-screen assignment by reading it back; this path has no service completion signal.
    // It does not participate in the helper wallpaper-mutation lock; see docs/decisions/D010-single-screen-wallpaper-apply.md.
    function applyHere(path) {
        const screenName = root.effectiveScreen ? String(root.effectiveScreen.name || "") : "";
        if (!screenName || !(Quickshell.screens || []).some(screen => screen.name === screenName)) {
            ToastService.showError(I18n.tr("VGS wallpaper error"), I18n.tr("Cannot tell which monitor this switcher is on — it may have been disconnected"));
            return;
        }
        // Enable per-monitor mode before a local apply. SessionData first seeds other outputs from their current wallpapers.
        const modeWasOff = !SessionData.perMonitorWallpaper;
        if (modeWasOff)
            SessionData.setPerMonitorWallpaper(true);
        SessionData.setMonitorWallpaper(screenName, path);
        if (SessionData.getMonitorWallpaper(screenName) !== path) {
            // Roll back mode enablement if the assignment fails. Retained entries are ignored while disabled and reseeded on enable.
            if (modeWasOff)
                SessionData.setPerMonitorWallpaper(false);
            ToastService.showError(I18n.tr("VGS wallpaper error"), I18n.tr("The wallpaper for this monitor did not take") + " (" + screenName + ")");
        }
    }

    onApplied: item => {
        const route = root.activationRoute(item);
        if (route === "fetch")
            VGSThemeCatalogService.fetchImagery(root.appliedTheme, item.card);
        if (route !== "wallpaper")
            return;
        if (root.applyRoute(root.applyToAllMonitors, root.screenCount) === "screen")
            root.applyHere(item.key);
        else
            applyReporter.track(VGSThemeService.setWallpaper(item.key));
    }

    // Use Connections so this reset coexists with the base open handler.
    Connections {
        target: root

        function onOpened() {
            root.applyToAllMonitors = true;
            root.source = SettingsData.wallpaperSource === "folder" ? "all" : "theme";
            root.refreshSource();
        }
    }

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS wallpaper error")
    }


    Component {
        id: scopePill

        SwitcherSegmentPill {
            labels: [I18n.tr("All monitors"), I18n.tr("This monitor")]
            activeIndex: root.applyToAllMonitors ? 0 : 1
            // Both segments flip through the one signal Tab drives.
            onPicked: root.scopeFlipRequested()
        }
    }

    Component {
        id: sourcePill

        SwitcherSegmentPill {
            labels: [I18n.tr("Theme"), I18n.tr("All")]
            activeIndex: root.source === "all" ? 1 : 0
            onPicked: index => {
                root.source = index === 1 ? "all" : "theme";
                root.refreshSource();
            }
        }
    }

    // Under All, a right-click offers Add to theme; an entry already in the applied theme says so instead.
    Component {
        id: addToThemeMenu

        Rectangle {
            id: menu

            readonly property bool inTheme: (root.menuItem || {}).marked === true

            width: menuLabel.width + Theme.spacingM * 2
            height: menuLabel.height + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceText, 0.2)

            StyledText {
                id: menuLabel
                anchors.centerIn: parent
                text: menu.inTheme ? I18n.tr("Already in %1").arg(root.appliedTheme) : I18n.tr("Add to theme")
                font.pixelSize: Theme.fontSizeLarge
                color: Theme.surfaceText
                opacity: menu.inTheme ? 0.6 : 1
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (!menu.inTheme)
                        VGSThemeService.wallpaperAdd(root.menuItem.key, true);
                    root.menuItem = null;
                }
            }
        }
    }
}
