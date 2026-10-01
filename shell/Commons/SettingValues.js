.pragma library

var UNITS = ["seconds", "minutes", "hours", "days"];
var FORMATS = ["datetime"];
var PROBLEM_TEXT = {
    empty: "Enter a date or time format.",
    multiline: "Use one line.",
    "too-long": "Use at most 64 characters.",
    "unclosed-quote": "Close the quoted text.",
    "no-field": "Use at least one date or time field, such as HH, mm or ddd."
};

var CONTROL_OR_SEPARATOR = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
var DATETIME_FIELD = /[dMyhHmszaAt]/;

function unitStep(unit) {
    switch (unit) {
    case "seconds": return 1;
    case "minutes": return 60;
    case "hours": return 3600;
    case "days": return 86400;
    }
    throw new Error("SettingValues.quantityText: unit " + JSON.stringify(unit) + " is not one of " + UNITS.join(", "));
}

function quantityText(value, unit) {
    if (UNITS.indexOf(unit) === -1)
        throw new Error("SettingValues.quantityText: unit " + JSON.stringify(unit) + " is not one of " + UNITS.join(", "));
    var base = unitStep(unit);
    var chosen = unit;
    var shown = value;
    if (value !== 0) {
        for (var i = UNITS.indexOf(unit) + 1; i < UNITS.length; i++) {
            var factor = unitStep(UNITS[i]) / base;
            if (value % factor === 0) {
                chosen = UNITS[i];
                shown = value / factor;
            }
        }
    }
    var singular = chosen.slice(0, -1);
    return String(shown) + " " + (shown === 1 ? singular : chosen);
}

function datetimeFormatProblem(text) {
    if (text === "") return "empty";
    if (CONTROL_OR_SEPARATOR.test(text)) return "multiline";
    if (text.length > 64) return "too-long";
    var quoted = false;
    var hasField = false;
    for (var i = 0; i < text.length; i++) {
        var ch = text.charAt(i);
        if (ch === "'") {
            if (text.charAt(i + 1) === "'") {
                i += 1;
                continue;
            }
            quoted = !quoted;
            continue;
        }
        if (!quoted && DATETIME_FIELD.test(ch))
            hasField = true;
    }
    if (quoted) return "unclosed-quote";
    return hasField ? "" : "no-field";
}

function presetText(entry, preset, formatDate) {
    if (preset.label !== undefined) return preset.label;
    if (entry.format === "datetime") return formatDate(preset.value);
    if (entry.type === "number" && entry.unit !== undefined) return quantityText(preset.value, entry.unit);
    return String(preset.value);
}
