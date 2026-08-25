pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Full-screen wallpaper switcher (`vshell ipc call wallpaper-switcher open`).
//
// Scope is the active theme's `backgrounds/` set only — the same list the dash's
// Wallpapers tab shows in "theme" mode. The user's own wallpaper folder stays a
// dash/settings concern; this surface is the theme's own set at full size.
//
// On a multi-monitor setup a pill above the rail chooses where Enter applies:
// every monitor (the default on every open) or only the one the switcher is
// on. Tab flips it, a click selects the segment under the cursor — the base
// takes Tab off paging while the pill is up. One monitor has nothing to
// choose, so the pill is not there at all.
FullScreenSwitcher {
    id: root

    filterable: false
    // A wallpaper's filename tells the user nothing the picture does not, and
    // naming it under the rail is chrome Omarchy's background switcher does not
    // carry either.
    showLabels: false
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
    readonly property int screenCount: (Quickshell.screens || []).length
    // Where Enter applies. Reset to all monitors on every open (the
    // Connections below): a scope chosen yesterday and silently still aimed
    // at one monitor is how a pick lands somewhere unexpected.
    property bool applyToAllMonitors: true

    // BEGIN WALLPAPER SCOPE DECISION
    // The scope arithmetic, with every input an argument so
    // scripts/test-switcher-scope.js can execute it — the same contract as
    // the base's SWITCHER SELECTION DECISION region: nothing here may
    // reference `root`, `Theme`, `I18n` or `Qt`.

    // Whether there is a scope to choose. One monitor leaves nothing to
    // point at: the pill hides and Tab stays on paging.
    function scopeChoiceExists(screenCount) {
        return screenCount > 1;
    }

    // Which entry the switcher opens on. In "this monitor" the seed is what
    // is ON this screen, with the service's optimistic claim as the fallback
    // for an apply that has not committed yet. In "all monitors" a single
    // current entry only exists when every screen shows the same thing; any
    // disagreement seeds "" — the top of the list — because calling one
    // screen's picture "current" for all of them is true of no monitor.
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

    // Where Enter routes the apply: "service" is the every-monitor path
    // through VGSThemeService, "screen" writes one monitor's assignment. A
    // single monitor always takes the service path — the scope can be stale
    // ("this monitor" chosen, then the other monitor unplugged mid-open) —
    // and the service path is the one that carries apply reporting.
    function applyRoute(allMonitors, screenCount) {
        if (allMonitors || !scopeChoiceExists(screenCount))
            return "service";
        return "screen";
    }
    // END WALLPAPER SCOPE DECISION

    // Land on the wallpaper already in use FOR THE CHOSEN SCOPE, so paging
    // starts from where the desktop is, not from the top of the list.
    //
    // `SessionData` first, because that is what is ON the desktop and not
    // everything that changes it goes through this service: wallpaper cycling
    // writes SessionData directly, so seeding from the service's own
    // `selectedWallpaper` opened the switcher on whatever it last applied
    // rather than on the picture the user is looking at. The service value is
    // the fallback for the window where an apply has claimed a wallpaper
    // optimistically but has not committed it yet.
    //
    // Per SCREEN, because under per-monitor mode the global path is not what
    // any monitor is showing. `getMonitorWallpaper` is the one accessor for
    // this: it already answers with the global path when per-monitor mode is
    // off or the screen has no assignment of its own, so there is no mode to
    // branch on here — `scopeSeedKey` only decides whose answer counts.
    activeKey: {
        const screenName = root.effectiveScreen ? String(root.effectiveScreen.name || "") : "";
        const shown = screenName ? SessionData.getMonitorWallpaper(screenName) : SessionData.wallpaperPath;
        const everywhere = (Quickshell.screens || []).map(screen => SessionData.getMonitorWallpaper(screen.name));
        return root.scopeSeedKey(root.applyToAllMonitors, everywhere, shown, VGSThemeService.selectedWallpaper || "");
    }
    // An apply not already running, not the whole service — see
    // ThemeSwitcherModal. Gates BOTH routes: a service apply that succeeds
    // late propagates its wallpaper to every monitor, which would silently
    // overwrite a single-screen assignment made while it ran.
    canApply: !applyReporter.anyApplyInFlight

    // A pathless entry is the apply id as well as the image: `setWallpaper`
    // refuses it and never answers, so it must not be reachable at all.
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

    // The single-screen apply. SessionData owns per-monitor assignments, but
    // unlike the service path nothing on it reports failure, so the screen is
    // checked first and the write is read back: a write that can fail with
    // nothing said is the failure mode the service path exists to avoid.
    // REVISIT(D010): VGS-211's wallpaper-mutation lock should cover this
    // write too.
    function applyHere(path) {
        const screenName = root.effectiveScreen ? String(root.effectiveScreen.name || "") : "";
        if (!screenName || !(Quickshell.screens || []).some(screen => screen.name === screenName)) {
            ToastService.showError(I18n.tr("VGS wallpaper error"), I18n.tr("Cannot tell which monitor this switcher is on — it may have been disconnected"));
            return;
        }
        // Product decision (VGS-212): picking "This monitor" with per-monitor
        // mode off turns the mode ON rather than bouncing the user to Settings.
        // The enable itself is what keeps that off the other monitors —
        // SessionData seeds every screen from what it currently shows before it
        // flips the flag, so this apply is the only thing that changes.
        const modeWasOff = !SessionData.perMonitorWallpaper;
        if (modeWasOff)
            SessionData.setPerMonitorWallpaper(true);
        SessionData.setMonitorWallpaper(screenName, path);
        if (SessionData.getMonitorWallpaper(screenName) !== path) {
            // The flip above must not outlive a refused write: the wallpaper
            // failure is toasted, but every monitor silently switched to
            // per-monitor rendering would be a global change nothing reported.
            // The entries the enable seeded can stay: with the mode off nothing
            // reads them, and the next enable reseeds from current state.
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

    // The base's own per-open reset is a self-targeted Connections for the
    // same reason this one is: an inline `onOpened:` here would replace it.
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

    // The pill: no card, no solid chrome — a light semi-transparent capsule
    // that reads over a wallpaper, like every other word on this surface.
    Component {
        id: scopePill

        Rectangle {
            width: segments.width + Theme.spacingXXS * 2
            height: segments.height + Theme.spacingXXS * 2
            radius: height / 2
            color: Theme.withAlpha(Theme.background, 0.45)
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceText, 0.2)

            // Below the segments in stacking order: consumes a click on the
            // pill's own padding, or a near-miss on the capsule falls through
            // to the click-away MouseArea and dismisses the whole switcher.
            MouseArea {
                anchors.fill: parent
            }

            Row {
                id: segments
                anchors.centerIn: parent

                Repeater {
                    // Segment order mirrors the boolean: index 0 is "all".
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

                        // Clicking a segment SELECTS it, through the same
                        // signal Tab drives when that means flipping — and a
                        // no-op on the one already active: a control drawn as
                        // two labeled choices must not activate the opposite
                        // of the label under the cursor.
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
