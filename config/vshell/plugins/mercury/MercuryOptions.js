.pragma library
//
// What the Mercury plugin's settings surfaces OFFER, and how to read a stored
// value against it. Split from MercuryLogic.js because it answers a different
// question -- that file decides things about transactions, this one is a
// catalogue -- and because one file holding both outgrew the repo's size gate.
//
// Its whole reason to exist is that there are two settings surfaces: the
// popout's own page and the page in the settings application. A second list
// would be one rename away from offering different sets, so there is one, and
// both read it.
//
// It imports nothing, so there is no cycle with MercuryLogic.js and the test
// evaluates each region on its own.

// BEGIN MERCURY OPTIONS

// Array-like, duck-typed for the same reason MercuryLogic.js is: a strict
// [object Array] tag test answers false in QML for a list that has been
// through an engine round trip, and true in Node. These lists are literals
// from this file, but the rule is the rule.
function isOptionList(value) {
    return !!value && typeof value !== "string" && typeof value.length === "number";
}

// The option lists, defined once so the popout's settings page and the
// settings app's page cannot drift apart or offer different sets.
// One label per option, because both settings surfaces render these in a
// dropdown, which has room for the sentence.
function daysOptions() {
    return [{ value: "1", label: "24 hours" },
            { value: "5", label: "5 days" },
            { value: "10", label: "10 days" },
            { value: "30", label: "30 days" },
            { value: "60", label: "60 days" }];
}

function refreshOptions() {
    return [{ value: "60", label: "Every minute" },
            { value: "300", label: "Every 5 minutes" },
            { value: "900", label: "Every 15 minutes" },
            { value: "3600", label: "Hourly" }];
}

function pillModeOptions() {
    return [{ value: "full", label: "$3,701.86" },
            { value: "noCents", label: "$3,702" },
            { value: "compact", label: "$3.7K" },
            { value: "hidden", label: "Icon only" }];
}

// Where a stored value sits in its list, or -1 when the list no longer offers
// it. The two readings below are the only callers, so the search happens once.
function optionSlot(options, stored) {
    var list = isOptionList(options) ? options : [];
    var text = String(stored === null || stored === undefined ? "" : stored);
    for (var i = 0; i < list.length; i++) {
        if (String(list[i].value) === text)
            return i;
    }
    return -1;
}

// A stored setting is only honoured while it is still one of the offered
// values; anything else falls back, so a hand-edited settings file cannot
// leave the bar showing nothing with no control that can reach it.
function optionValue(options, stored, fallback) {
    var slot = optionSlot(options, stored);
    return slot >= 0 ? String(options[slot].value) : fallback;
}

// END MERCURY OPTIONS
