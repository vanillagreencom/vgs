// Toast actions: the data half of "this toast tells you to go somewhere".
//
// A toast that says "Settings > Notifications can take it over" and then makes
// the user go find it is a dead end. The fix is a button, and the button needs
// somewhere to point. Two forms are accepted:
//
//   { label: "Open settings", settingsTab: "notifications" }   declarative
//   { label: "Use VGS", callback: function () { ... } }        live handler
//
// The declarative form is preferred and is what every navigate-to-settings
// caller should use. It is a plain string, so nothing survives the toast it was
// attached to, and no caller has to capture a closure over PopoutService just
// to open a tab.
//
// The callback form exists for the cases that are not navigation (the
// notification takeover runs a helper, it does not open a tab). It is a live
// reference, so ToastService is responsible for dropping it: the queue entry is
// released when the entry is dropped, and the displayed toast's copy is nulled
// by hideToast(). See scripts/test-toast-actions.js, which proves both.

// Returns a plain {label, settingsTab, callback} record, or null when the
// argument is not a usable action. Normalising at enqueue time means the queue
// never holds a half-formed action, and never holds a reference to the caller's
// own object.
function normalizeAction(action) {
    if (!action || typeof action !== "object")
        return null;

    var label = typeof action.label === "string" ? action.label.trim() : "";
    if (!label)
        return null;

    var settingsTab = typeof action.settingsTab === "string" ? action.settingsTab.trim() : "";
    var callback = typeof action.callback === "function" ? action.callback : null;

    // A label with nowhere to go is a button that does nothing, which is worse
    // than the prose it replaced.
    if (!settingsTab && !callback)
        return null;

    // A settings tab wins over a callback when both are given: the declarative
    // form is the one whose behaviour is inspectable, and silently preferring
    // the closure would make the two forms differ by declaration order.
    return {
        label: label,
        settingsTab: settingsTab,
        callback: settingsTab ? null : callback
    };
}

function hasAction(normalized) {
    return !!(normalized && normalized.label && (normalized.settingsTab || normalized.callback));
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        normalizeAction: normalizeAction,
        hasAction: hasAction
    };
}
