// USB serials and compositor serials can differ on Apple displays. A model fallback
// is usable only when it identifies one control device; otherwise the user pins it.
function brightnessDeviceName(outputName, output, devices, pinned) {
    const available = devices.filter(device => ["apple", "ddc", "backlight"].includes(device.class));
    if (pinned)
        return available.find(device => device.name === pinned)?.name || "";
    const connector = available.filter(device => device.connector === outputName);
    if (connector.length === 1)
        return connector[0].name;
    const serial = available.filter(device => output.serial && device.serial === output.serial);
    if (serial.length === 1)
        return serial[0].name;
    if (/^eDP-|^LVDS-/.test(outputName)) {
        const panels = available.filter(device => device.class === "backlight");
        if (panels.length === 1)
            return panels[0].name;
    }
    const model = (output.model || "").toLowerCase().replace(/[^a-z0-9]/g, "");
    const matches = available.filter(device => model && (device.label || "").toLowerCase().replace(/[^a-z0-9]/g, "").endsWith(model));
    return matches.length === 1 ? matches[0].name : "";
}

function displayName(output, name) {
    const model = output?.model || "";
    if (model === "ProDisplayXDR")
        return "Pro Display XDR";
    if (model === "StudioDisplay")
        return "Studio Display";
    return model || name;
}

function previewScales(values, current) {
    const choices = values.filter(value => value >= 1 && value <= 3.2);
    if (Number.isFinite(current) && current > 0 && !choices.some(value => Math.abs(value - current) < 0.001))
        choices.push(current);
    choices.sort((a, b) => b - a);
    if (choices.length <= 5)
        return choices;
    const index = choices.findIndex(value => Math.abs(value - current) < 0.001);
    const start = Math.max(0, Math.min(choices.length - 5, index - 2));
    return choices.slice(start, start + 5);
}
