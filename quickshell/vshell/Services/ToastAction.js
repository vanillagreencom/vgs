// Toast actions accept a settingsTab destination or a callback with a label.
// Prefer settingsTab for navigation. ToastService releases callbacks when displayed or queued actions are discarded.

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
