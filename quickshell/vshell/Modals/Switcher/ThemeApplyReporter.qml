pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// One apply, one reply — the shared half of both switchers' result reporting.
//
// Driven from a keybind there is no settings tab loaded to report a failed theme
// or wallpaper apply, so the switcher reports its own. It cannot do that by
// consuming the NEXT `VGSThemeService.applyCompleted`: 19 unrelated operations
// emit that signal from over 40 sites, several of them long background tasks the `busy`
// counter deliberately cannot see, so "the next one" is whichever command
// happened to land first — a preview regeneration started from the dash would
// be toasted as the switcher's apply, and the switcher's own failure would then
// go unreported. `applyFinished` carries the request id instead, and only the
// request this reporter started is consumed.
//
// Success is silent: the desktop shows it, and an open Themes tab already
// info-toasts the same completion.
QtObject {
    id: reporter

    // Toast title for a failed apply.
    property string errorTitle: ""
    // The request this surface is waiting on; "" when it is waiting on nothing.
    // NOT cleared on open or close: the user asked for this apply, so its
    // failure is still theirs to hear about, and correlation by id is what keeps
    // an unrelated completion from clearing it.
    property string pendingRequest: ""

    // SERVICE-WIDE, and named so: true while ANY apply is running, not only the
    // one this surface started. The report is correlated by request id; the GATE
    // deliberately is not, because two applies racing the same theme files is the
    // thing to prevent whichever surface started them. It is still far tighter
    // than `busy`, which counts every non-background command and misses the
    // background ones.
    readonly property bool anyApplyInFlight: VGSThemeService.applyInFlight

    // `requestId` is what `applyBlueprint`/`setWallpaper` returned. "" means the
    // service refused the request outright, so there is no reply to wait for and
    // arming would leave the latch set forever.
    function track(requestId) {
        reporter.pendingRequest = requestId || "";
    }

    property Connections _replies: Connections {
        target: VGSThemeService
        function onApplyFinished(requestId, success, message) {
            if (reporter.pendingRequest === "" || requestId !== reporter.pendingRequest)
                return;
            reporter.pendingRequest = "";
            if (!success)
                ToastService.showError(reporter.errorTitle, message);
        }

        // A request replaced before it launched gets no `applyFinished`. Nothing
        // failed, so nothing is toasted — the latch just stops waiting for a
        // reply that is never coming.
        function onApplySuperseded(requestId) {
            if (reporter.pendingRequest !== "" && requestId === reporter.pendingRequest)
                reporter.pendingRequest = "";
        }
    }
}
