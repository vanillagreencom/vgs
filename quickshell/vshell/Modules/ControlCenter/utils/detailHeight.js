// Resolve a control centre section height. A detail with no height request passes 0 and uses the section default.
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
