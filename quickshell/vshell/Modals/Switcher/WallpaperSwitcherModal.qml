pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Switch wallpapers from the active theme's set. The user-folder picker remains in Dash/settings.
// With several monitors, choose all outputs or this output; each open starts with all outputs selected.
FullScreenSwitcher {
    id: root

    filterable: false

    showLabels: false
    layerNamespace: "vshell:wallpaper-switcher"

    // An empty list after a failed read has no retained fallback. Report the wallpaper read's error instead of claiming the theme has no images.
    emptyText: VGSThemeService.wallpapersLoadFailed ? I18n.tr("Could not read this theme's wallpapers") + (VGSThemeService.wallpapersLoadError ? "\n" + VGSThemeService.wallpapersLoadError : "") : I18n.tr("This theme has no wallpapers")

    // Share retained-list wording with Dash; after a failed theme change the paths can belong to the previous theme.
    staleNotice: VGSThemeService.wallpapersStaleNotice

    readonly property var wallpaperEntries: VGSThemeService.themeWallpapers || []
    readonly property int screenCount: (Quickshell.screens || []).length
    // Reset apply scope to all monitors on each open so a previous local choice cannot silently carry over.
    property bool applyToAllMonitors: true

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
    items: root.wallpaperEntries.filter(entry => !!entry.path).map(entry => ({
                image: entry.path,
                thumb: entry.thumb || "",
                label: entry.file,
                key: entry.path
            }))

    scopeToggle: root.scopeChoiceExists(root.screenCount) ? scopePill : null
    onScopeFlipRequested: root.applyToAllMonitors = !root.applyToAllMonitors

    function show() {
        VGSThemeService.refreshWallpapers();
        open();
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
        }
    }

    ThemeApplyReporter {
        id: applyReporter
        errorTitle: I18n.tr("VGS wallpaper error")
    }


    Component {
        id: scopePill

        Rectangle {
            width: segments.width + Theme.spacingXXS * 2
            height: segments.height + Theme.spacingXXS * 2
            radius: height / 2
            color: Theme.withAlpha(Theme.background, 0.45)
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceText, 0.2)

            // Consume clicks on scope-control padding so near misses cannot fall through to click-away dismissal.
            MouseArea {
                anchors.fill: parent
            }

            Row {
                id: segments
                anchors.centerIn: parent

                Repeater {

                    model: [I18n.tr("All monitors"), I18n.tr("This monitor")]

                    Rectangle {
                        id: segment

                        required property int index
                        required property var modelData
                        readonly property bool active: root.applyToAllMonitors === (segment.index === 0)

                        width: segmentLabel.width + Theme.spacingM * 2
                        height: segmentLabel.height + Theme.spacingXS * 2
                        radius: height / 2
                        color: segment.active ? Theme.withAlpha(Theme.surfaceText, 0.22) : "transparent"

                        StyledText {
                            id: segmentLabel
                            anchors.centerIn: parent
                            text: segment.modelData
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.surfaceText
                            opacity: segment.active ? 1 : 0.7
                        }

                        // Clicking selects the labeled scope. Emit the shared toggle signal only when that selection changes.
                        MouseArea {
                            anchors.fill: parent
                            onClicked: if (!segment.active) root.scopeFlipRequested()
                        }
                    }
                }
            }
        }
    }
}
