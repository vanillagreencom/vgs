pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// One apply, one reply — the shared half of both switchers' result reporting.
//
// Driven from a keybind there is no settings tab loaded to report a failed theme
// or wallpaper apply, so the switcher reports its own. It cannot do that by
// consuming the NEXT `VGSThemeService.applyCompleted`: roughly 25 unrelated
// operations emit that signal, several of them long background tasks the `busy`
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

    // True only while an apply is running — not while any counted command is,
    // which is what `busy` reports and which a switcher's Enter must not wait on.
    readonly property bool applyInFlight: VGSThemeService.applyInFlight

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
    }
}
