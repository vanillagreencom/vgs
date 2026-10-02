.pragma library

// The Browser theming row of the plugin's Settings page, pure so
// scripts/test-themes-setup.js runs it under node: what `vgsh theme setup
// --json` says of the chromium target's one-time setup, the writer
// `vgsh theme browser-policy install` puts on PATH
// (docs/architecture/theme-browsers.md § Chromium).

// The shipped target whose setup the row reports.
var TARGET = "chromium";
// The states `vgsh theme setup` reports a setup in.
var STATES = ["not-detected", "absent", "done"];

// The `browserTheming` status value, a `state`, for TEXT, the setup
// report's stdout, and CODE, its exit code, null for a report that did not
// start: Installed once the writer is on
// PATH; Not installed with the manifest's Install browser theming action
// offered while a Chromium-family browser is and the writer is not; No
// browser found while none is; not shipped for a tree whose targets hold
// no chromium setup, as the smoke's sandbox tree ships none. A report that
// failed or does not parse reads as unknown, in the danger tone, and
// offers nothing.
function browserTheming(text, code) {
    var unknown = function (why) {
        console.warn("themes: setup=" + why);
        return { tone: "danger", text: "Browser theme setup could not be checked. Open Settings to check Themes." };
    };
    if (code === null) return unknown("did not start");
    if (code !== 0) return unknown("exited " + code);
    var report;
    try {
        report = JSON.parse(text);
    } catch (e) {
        return unknown("printed no report");
    }
    var rows = report !== null && typeof report === "object" && Array.isArray(report.setups) ? report.setups : null;
    if (rows === null) return unknown("printed no report");
    var row = null;
    for (var i = 0; i < rows.length; i++)
        if (rows[i] !== null && typeof rows[i] === "object" && rows[i].name === TARGET) row = rows[i];
    if (row === null) return { tone: "info", text: "This version of VGS does not support browser themes" };
    switch (row.state) {
    case "done": return { tone: "ok", text: "Browser theme support is installed" };
    case "absent": return { tone: "warning", text: "Browser themes are not installed", action: true };
    case "not-detected": return { tone: "info", text: "No Chromium-family browser found" };
    }
    return unknown("named the state " + JSON.stringify(row.state) + ", not one of " + STATES.join(", "));
}
