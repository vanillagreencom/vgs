function adjustmentKeys() {
    return ["brightness", "vibrancy", "contrast", "hue", "temperature"];
}

function normalizeAdjustments(adjustments) {
    var normalized = {};
    for (var key of adjustmentKeys())
        normalized[key] = Math.round(adjustments && adjustments[key] || 0);
    return normalized;
}

function restyleArgs(request) {
    var args = ["theme", "restyle"];
    if (request && request.reset === true) {
        args.push("--reset");
    } else {
        if (request && request.preview === true)
            args.push("--preview");
        var adjustments = normalizeAdjustments(request && request.adjustments);
        for (var key of adjustmentKeys())
            args.push("--" + key, String(adjustments[key]));
    }
    args.push("--json");
    return args;
}

function completionPolicy(request, transition, succeeded) {
    var preview = request && request.preview === true;
    return {
        markGreeter: succeeded === true && !preview,
        refresh: transition && transition.refresh === true && !preview,
        announce: transition && transition.announce === true && !preview
    };
}

function setAppBusy(pending, app, value) {
    var next = Object.assign({}, pending || {});
    if (value)
        next[app] = true;
    else
        delete next[app];
    return next;
}

function appToggleArgs(app, enabled) {
    return ["theme", "apps", enabled ? "--enable" : "--disable", app, "--json"];
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        adjustmentKeys: adjustmentKeys,
        normalizeAdjustments: normalizeAdjustments,
        restyleArgs: restyleArgs,
        completionPolicy: completionPolicy,
        setAppBusy: setAppBusy,
        appToggleArgs: appToggleArgs
    };
}
