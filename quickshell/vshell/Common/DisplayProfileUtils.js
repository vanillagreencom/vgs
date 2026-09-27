function _cleanText(value) {
    return String(value ?? "").trim();
}

function _parts(output, includeSerial) {
    const parts = [];
    const make = _cleanText(output?.make);
    const model = _cleanText(output?.model);
    const serial = _cleanText(output?.serial);
    if (make)
        parts.push(make);
    if (model)
        parts.push(model);
    if (includeSerial && serial)
        parts.push(serial);
    return parts;
}

function _desc(parts) {
    return ("desc:" + parts.join(" ")).replace(/,/g, "");
}

function _modelName(output) {
    return _parts(output, false).join(" ").replace(/,/g, "");
}

function _fullName(output) {
    return _parts(output, true).join(" ").replace(/,/g, "");
}

function _stripLegacyUnknown(text) {
    return _cleanText(text).replace(/\s+Unknown$/, "").trim();
}

function getOutputIdentifier(output, outputName, displayNameMode, compositor) {
    if (displayNameMode === "model" && output?.make && output?.model) {
        if (compositor === "niri") {
            const serial = output.serial || "Unknown";
            return output.make + " " + output.model + " " + serial;
        }
        return output.make + " " + output.model;
    }
    return outputName;
}

function getHyprlandOutputIdentifier(output, outputName, displayNameMode, legacyUnknown) {
    if (displayNameMode === "model" && output?.make && output?.model) {
        const serial = _cleanText(output?.serial);
        const parts = _parts(output, true);
        if (legacyUnknown && !serial)
            parts.push("Unknown");
        return _desc(parts);
    }
    return outputName;
}

function modeString(mode) {
    if (!mode)
        return null;
    const refresh = mode.refresh_rate !== undefined ? mode.refresh_rate : mode.refresh;
    return mode.width + "x" + mode.height + "@" + (refresh / 1000).toFixed(3);
}

function modeIndexForConfig(liveModes, configuredMode) {
    return (liveModes || []).findIndex(m => modeString(m) === configuredMode);
}

function profileKeyMatchesOutput(outputId, output, outputName, displayNameMode, compositor) {
    const key = _cleanText(outputId);
    if (!key)
        return false;

    const directMatches = [
        outputName,
        getOutputIdentifier(output, outputName, displayNameMode, compositor),
        _modelName(output),
        _fullName(output)
    ];
    if (compositor === "hyprland") {
        directMatches.push(getHyprlandOutputIdentifier(output, outputName, "model", false));
        directMatches.push(getHyprlandOutputIdentifier(output, outputName, "model", true));
    }
    if (directMatches.some(candidate => _cleanText(candidate) === key))
        return true;

    if (!key.startsWith("desc:") || !output?.make)
        return false;

    const want = _stripLegacyUnknown(key.slice(5).replace(/,/g, ""));
    const full = _fullName(output);
    const noSerial = _modelName(output);
    return want === full || want === noSerial || full.startsWith(want + " ");
}

function matchingOutputNames(outputId, outputs, displayNameMode, compositor) {
    const matches = [];
    for (const name in (outputs || {})) {
        if (profileKeyMatchesOutput(outputId, outputs[name], name, displayNameMode, compositor))
            matches.push(name);
    }
    return matches;
}

function configEntryMatchesOutputs(configEntry, outputs, displayNameMode, compositor) {
    const cfgOutputs = configEntry?.outputs || {};
    const cfgKeys = Object.keys(cfgOutputs);
    const liveNames = Object.keys(outputs || {});
    if (cfgKeys.length !== liveNames.length)
        return false;

    const used = {};
    for (const key of cfgKeys) {
        const candidates = liveNames.filter(name => !used[name] && profileKeyMatchesOutput(key, outputs[name], name, displayNameMode, compositor));
        if (candidates.length !== 1)
            return false;
        used[candidates[0]] = true;
    }
    return true;
}

function configEntryMatchesLiveLayout(configEntry, outputs, displayNameMode, compositor) {
    const cfgOutputs = configEntry?.outputs || {};
    for (const outputId in cfgOutputs) {
        const cfg = cfgOutputs[outputId] || {};
        const candidates = matchingOutputNames(outputId, outputs, displayNameMode, compositor);
        if (candidates.length !== 1)
            return false;
        const live = outputs[candidates[0]];
        const cfgDisabled = cfg.disabled ?? false;
        const liveDisabled = !(live?.enabled ?? true);
        if (cfgDisabled !== liveDisabled)
            return false;
        if (cfgDisabled)
            continue;

        const mode = (live.modes && live.current_mode >= 0) ? live.modes[live.current_mode] : null;
        const liveMode = modeString(mode);
        if (cfg.mode && liveMode !== cfg.mode)
            return false;
        if ((cfg.position?.x ?? 0) !== (live.logical?.x ?? 0) || (cfg.position?.y ?? 0) !== (live.logical?.y ?? 0))
            return false;
        if (Math.abs((cfg.scale ?? 1.0) - (live.logical?.scale ?? 1.0)) > 0.001)
            return false;
        if ((cfg.transform ?? "Normal") !== (live.logical?.transform ?? "Normal"))
            return false;
    }
    return true;
}
