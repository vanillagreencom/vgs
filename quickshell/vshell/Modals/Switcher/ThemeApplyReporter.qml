pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

// Report failed switcher applies by request id. Shared completion signals can belong to unrelated operations.
// Successful applies need no additional toast here.
QtObject {
    id: reporter


    property string errorTitle: ""
    // Pending apply id, or empty when idle. Keep it across open/close so a late failure can still be reported.
    property string pendingRequest: ""

    // Block while any service apply is active to avoid competing writes, while reporting only this reporter's request id.
    readonly property bool anyApplyInFlight: VGSThemeService.applyInFlight

    // Track the id returned by applyBlueprint/setWallpaper. Empty means refusal, with no reply to await.
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
