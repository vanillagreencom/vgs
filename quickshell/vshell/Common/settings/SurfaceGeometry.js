.pragma library

function normalizeTarget(value) {
    var target = String(value || "sync");
    // Accept the persisted hyprland value as the compositor-only option.
    if (target === "hyprland")
        return "compositor";
    if (target === "quickshell" || target === "compositor")
        return target;
    return "sync";
}

function targetIndex(value) {
    switch (normalizeTarget(value)) {
    case "quickshell":
        return 1;
    case "compositor":
        return 2;
    default:
        return 0;
    }
}

function targetFromIndex(index) {
    switch (index) {
    case 1:
        return "quickshell";
    case 2:
        return "compositor";
    default:
        return "sync";
    }
}

function appliesToQuickshell(value) {
    return normalizeTarget(value) !== "compositor";
}

function appliesToCompositor(value) {
    return normalizeTarget(value) !== "quickshell";
}

function appliesToHyprland(value) {
    return appliesToCompositor(value);
}

function boundedInt(value, fallback, lo, hi) {
    var parsed = Math.round(Number(value));
    if (isNaN(parsed))
        parsed = fallback;
    return Math.max(lo, Math.min(hi, parsed));
}

function optionalNonnegativeInt(value, lo, hi) {
    var parsed = Math.round(Number(value));
    if (isNaN(parsed) || parsed < 0)
        return null;
    return Math.max(lo, Math.min(hi, parsed));
}

function effectiveHyprlandRadius(targetValue, cornerRadius, hyprlandRadius) {
    var target = normalizeTarget(targetValue);
    var shellRadius = boundedInt(cornerRadius, 15, 0, 20);
    var hyprRadius = optionalNonnegativeInt(hyprlandRadius, 0, 20);
    return target === "sync" ? shellRadius : (hyprRadius !== null ? hyprRadius : shellRadius);
}

function effectiveHyprlandBorderWidth(targetValue, surfaceBorderWidth, hyprlandBorderWidth) {
    var target = normalizeTarget(targetValue);
    var shellBorder = boundedInt(surfaceBorderWidth, 1, 0, 10);
    var hyprBorder = optionalNonnegativeInt(hyprlandBorderWidth, 0, 10);
    return target === "sync" ? shellBorder : (hyprBorder !== null ? hyprBorder : shellBorder);
}

function effectiveCompositorRadius(targetValue, cornerRadius, compositorRadius) {
    return effectiveHyprlandRadius(targetValue, cornerRadius, compositorRadius);
}

function effectiveCompositorBorderWidth(targetValue, surfaceBorderWidth, compositorBorderWidth) {
    return effectiveHyprlandBorderWidth(targetValue, surfaceBorderWidth, compositorBorderWidth);
}
