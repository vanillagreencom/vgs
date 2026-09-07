.pragma library

// Surface shape is one radius and one border thickness, applied to VGS surfaces and to
// app windows alike. Earlier releases let the two diverge through a target selector and a
// second pair of compositor-only values; SettingsStore's version 25 step folds those away.

function boundedInt(value, fallback, lo, hi) {
    var parsed = Math.round(Number(value));
    if (isNaN(parsed))
        parsed = fallback;
    return Math.max(lo, Math.min(hi, parsed));
}

function effectiveRadius(cornerRadius) {
    return boundedInt(cornerRadius, 15, 0, 20);
}

function effectiveBorderWidth(surfaceBorderWidth) {
    return boundedInt(surfaceBorderWidth, 1, 0, 10);
}
