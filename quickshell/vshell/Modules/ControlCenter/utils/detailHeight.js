// The expanded height for one control centre section.
//
// `contentHeight` is what the loaded detail says it needs; sections whose
// detail publishes nothing pass 0 and keep their fixed height. Fitting the
// content matters at both ends: two paired Bluetooth devices used to sit above
// 200 px of empty panel, and the audio lists scrolled inside 250 px.
function detailHeightForSection(section, maxHeight, pluginInstance, contentHeight) {
    if (!section)
        return 0;
    if (section === "wifi" || section === "bluetooth"
            || section === "builtin_vpn" || section === "builtin_tailscale")
        return Math.min(fitted(350, contentHeight), maxHeight);
    if (section === "audioOutput" || section === "audioInput")
        return Math.min(fitted(420, contentHeight), maxHeight);
    if (section.startsWith("brightnessSlider_"))
        return Math.min(400, maxHeight);
    if (section.startsWith("plugin_")) {
        const h = pluginInstance ? pluginInstance.ccDetailHeight : 0;
        return Math.min(h > 0 ? h : 250, maxHeight);
    }
    return Math.min(250, maxHeight);
}

// A short detail shrinks to its content; a long one keeps the section's cap and
// scrolls. The floor keeps an empty or scanning list from collapsing to a sliver.
function fitted(cap, contentHeight) {
    if (!contentHeight || contentHeight <= 0)
        return cap;
    return Math.max(120, Math.min(cap, Math.ceil(contentHeight)));
}
