.pragma library

// Record explicit widget removals separately from absence so hardware detection respects user choices.
// Only hardware-dependent widgets belong in this reconciliation list.
var HARDWARE_WIDGETS = [{
    // Presence key resolved by SettingsData.hardwareBarWidgetPresent().
    id: "battery",
    section: "rightWidgets",
    // Insert ahead of the first of these that is present, matching the shipped
    // default layout; append when none of them are.
    before: ["controlCenterButton"]
}];

var SECTIONS = ["leftWidgets", "centerWidgets", "rightWidgets"];

function entryId(entry) {
    if (typeof entry === "string")
        return entry;
    return (entry && entry.id) ? entry.id : "";
}

// Enabled or not: a disabled widget is still a decision the user made about it.
function barMentionsWidget(bar, widgetId) {
    if (!bar)
        return false;
    for (var s = 0; s < SECTIONS.length; s++) {
        var widgets = bar[SECTIONS[s]];
        if (!Array.isArray(widgets))
            continue;
        for (var i = 0; i < widgets.length; i++) {
            if (entryId(widgets[i]) === widgetId)
                return true;
        }
    }
    return false;
}

function configsMentionWidget(barConfigs, widgetId) {
    if (!Array.isArray(barConfigs))
        return false;
    for (var i = 0; i < barConfigs.length; i++) {
        if (barMentionsWidget(barConfigs[i], widgetId))
            return true;
    }
    return false;
}

// Return the first enabled bar, or -1 when none is enabled.
// Wait for an enabled bar rather than modifying a layout that cannot display the widget.
function targetBarIndex(barConfigs) {
    if (!Array.isArray(barConfigs))
        return -1;
    for (var i = 0; i < barConfigs.length; i++) {
        if (barConfigs[i] && barConfigs[i].enabled)
            return i;
    }
    return -1;
}

function insertionIndex(widgets, before) {
    if (!Array.isArray(before))
        return widgets.length;
    for (var i = 0; i < widgets.length; i++) {
        if (before.indexOf(entryId(widgets[i])) >= 0)
            return i;
    }
    return widgets.length;
}

// Returns a new barConfigs array when something was added, or null when there
// is nothing to do. `presence` maps widget id -> whether the hardware exists;
// a widget whose presence is unknown or false is never added.
function reconcile(barConfigs, removedWidgets, presence) {
    if (!Array.isArray(barConfigs) || barConfigs.length === 0)
        return null;

    var removed = Array.isArray(removedWidgets) ? removedWidgets : [];
    var next = null;
    var added = [];

    for (var h = 0; h < HARDWARE_WIDGETS.length; h++) {
        var spec = HARDWARE_WIDGETS[h];
        if (!presence || presence[spec.id] !== true)
            continue;
        if (removed.indexOf(spec.id) >= 0)
            continue;

        var source = next || barConfigs;
        if (configsMentionWidget(source, spec.id))
            continue;

        var index = targetBarIndex(source);
        if (index < 0)
            continue;

        next = JSON.parse(JSON.stringify(source));
        var bar = next[index];
        var widgets = Array.isArray(bar[spec.section]) ? bar[spec.section].slice() : [];
        // A bare id, exactly as the shipped default writes it: the widget then
        // follows the global option defaults instead of freezing a snapshot of
        // them into the config.
        widgets.splice(insertionIndex(widgets, spec.before), 0, spec.id);
        bar[spec.section] = widgets;
        added.push(spec.id);
    }

    if (!next)
        return null;
    return {
        barConfigs: next,
        added: added
    };
}
