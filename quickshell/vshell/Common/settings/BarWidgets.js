.pragma library

// Bar widget lists are user data: once a user has their own barConfigs, the
// shipped default array is replaced wholesale and nothing ever revisits it. A
// config authored on a desktop therefore has no "battery" entry, and moving it
// to a laptop yields a laptop with no battery indicator and no diagnostic.
//
// The fix is to record removals rather than only presence. "Absent because the
// user removed it" and "absent because this config was written on a machine
// without the hardware" are otherwise indistinguishable — both are just not in
// the array. SettingsData.removedBarWidgets carries the first case, so
// reconciliation may safely add a widget back whenever it was never mentioned
// at all, on every load, without ever fighting the user.
//
// Only widgets whose usefulness is decided by hardware belong here. Everything
// else stays exactly as the user left it.
var HARDWARE_WIDGETS = [{
    // Presence key resolved by SettingsData.hardwareBarWidgetPresent().
    id: "battery",
    // Section of the target bar the widget is inserted into.
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

// The bar a reconciled widget lands on: the first enabled one, so a user who
// disabled their desktop bar and added a laptop bar gets the widget where they
// can see it. Exactly one bar is touched — never every bar.
//
// -1 when there is no enabled bar. Falling back to the first bar would insert
// the widget somewhere that cannot render it, rewriting a layout the user
// deliberately turned off for no visible benefit. Reconciliation exists to
// surface hardware, so with nothing on screen to surface it on, it does
// nothing and waits for a bar to be enabled. Nothing is lost by waiting:
// SettingsData re-runs reconciliation when a bar is enabled or added, as well
// as on every load, so the widget appears as soon as there is somewhere to
// put it.
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
