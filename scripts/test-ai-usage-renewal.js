#!/usr/bin/env node

// Guards the aiUsage "Show renewal dates" contract (VGS-67).
//
// The whole feature is an opt-in: with the setting off the popout must render
// byte-for-byte what it rendered before, and with it on a bar whose renewal
// instant is unknown must gain NOTHING — no placeholder, no "1 Jan 1970". That
// contract lives entirely in three small functions and one property default,
// and every one of them is a guard returning an empty string. Nothing else in
// the suite can see them: qmllint only parses, and `qml-smoke.sh --nested`
// gives bundled plugins no behavioural coverage at all (VGS-19), nor can it
// see a ReferenceError (VGS-31). So a later edit loosening `=== true` to `!!`,
// or dropping the past-instant guard, would ship green.
//
// This runs the SHIPPED function bodies, extracted from the QML, rather than a
// copy of them — a copy drifts and then proves nothing.
//
// WHAT THE Qt STUBS DO NOT PROVE. Qt's two-argument toLocaleDateString /
// toLocaleTimeString are replaced with a minimal formatter, so this cannot show
// that Qt renders "ddd d MMM yyyy" the way the comments claim. What it does
// show is which tokens each formatter asks for — that the renewal line requests
// the year and the compact column does not, which is the documented difference
// between them — and, for everything else here, the guard logic, which is
// pure JavaScript and where the actual contract lives.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave this test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageWidget.qml");
const SETTINGS = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageSettings.qml");

const source = fs.readFileSync(WIDGET, "utf8");
const settingsSource = fs.readFileSync(SETTINGS, "utf8");

// Drop comments, keep everything else — string literals included, verbatim.
// For assertions that must NOT match, prose is the false-positive risk and
// string contents are load-bearing evidence, so this removes the first without
// touching the second. Single pass rather than sequential regexes, because a
// `//` inside a string, or a quote inside a comment, defeats that version.
function stripComments(src) {
    let out = "";
    for (let i = 0; i < src.length; ) {
        const c = src[i];
        const d = src[i + 1];
        if (c === "/" && d === "/") {
            while (i < src.length && src[i] !== "\n") i++;
            continue;
        }
        if (c === "/" && d === "*") {
            i += 2;
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
            i += 2;
            out += " ";
            continue;
        }
        if (c === '"' || c === "'" || c === "`") {
            out += c;
            i++;
            while (i < src.length && src[i] !== c) {
                // Copy an escape and whatever it escapes as one unit, so \" does
                // not read as the closing quote.
                if (src[i] === "\\" && i + 1 < src.length) {
                    out += src[i] + src[i + 1];
                    i += 2;
                    continue;
                }
                out += src[i];
                i++;
            }
            if (i < src.length) {
                out += src[i];
                i++;
            }
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

// The helper has to be shown capable of both jobs before it is trusted with
// them: a guard that silently stopped stripping, or started eating strings,
// would turn the assertion below into a permanent pass.
assert.equal(stripComments('a // root.x = 1\nb'), "a \nb", "stripComments must drop line comments");
assert.equal(stripComments("a /* root.x = 1 */ b"), "a   b", "stripComments must drop block comments");
assert.equal(stripComments('f("// not a comment")'), 'f("// not a comment")',
    "stripComments must not treat a // inside a string as a comment");
assert.equal(stripComments('f("a\\"// b")'), 'f("a\\"// b")',
    "stripComments must respect escaped quotes when scanning a string");

// ---- a fixed clock, and Qt's date API in miniature -------------------------

// Local-time construction, not an ISO string: the feature formats in the user's
// local zone, and a UTC literal would make these assertions pass or fail
// depending on where CI happens to run.
const NOW = new Date(2026, 7, 7, 12, 0, 0).getTime();
const SECOND = 1000;
const DAY = 86400 * SECOND;

const DDD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MMM = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function qtFormat(date, fmt) {
    const pad = n => String(n).padStart(2, "0");
    // Longest token first, so "ddd" is never eaten as three "d"s.
    return String(fmt).replace(/yyyy|MMM|ddd|HH|mm|d/g, token => {
        switch (token) {
        case "yyyy": return String(date.getFullYear());
        case "MMM": return MMM[date.getMonth()];
        case "ddd": return DDD[date.getDay()];
        case "HH": return pad(date.getHours());
        case "mm": return pad(date.getMinutes());
        case "d": return String(date.getDate());
        }
        return token;
    });
}

// Stands in for QML's Date: a frozen `now` (so "is this instant past?" is
// decidable here) plus Qt's two-argument locale formatters, which plain
// JavaScript does not have.
class QtDate extends Date {
    constructor(...args) {
        super(...(args.length ? args : [NOW]));
    }
    static now() {
        return NOW;
    }
    toLocaleDateString(_locale, fmt) {
        return qtFormat(this, fmt);
    }
    toLocaleTimeString(_locale, fmt) {
        return qtFormat(this, fmt);
    }
}

const Qt = { locale: () => "en_GB" };

// ---- extract and compile the shipped bodies --------------------------------

const bodies = {
    upcomingInstant: extractBlock(source, "function upcomingInstant(epoch)"),
    formatResetAt: extractBlock(source, "function formatResetAt(epoch)"),
    formatRenewalDate: extractBlock(source, "function formatRenewalDate(epoch)"),
    renewalLine: extractBlock(source, "function renewalLine(meter)"),
    hasRenewalLine: extractBlock(source, "function hasRenewalLine(meter)"),
    resetLabel: extractBlock(source, "function resetLabel(meter)"),
    setShowRenewalDates: extractBlock(source, "function setShowRenewalDates(on)"),
};

// If extraction ever silently grabs the wrong span, these fail loudly rather
// than leaving the assertions below testing an empty string.
assert.match(bodies.upcomingInstant, /getTime\(\) <= Date\.now\(\)/,
    "upcomingInstant must still be the single owner of the past-instant guard");
assert.match(bodies.formatRenewalDate, /upcomingInstant/,
    "formatRenewalDate must go through upcomingInstant, not re-implement the guard");
assert.match(bodies.formatResetAt, /upcomingInstant/,
    "formatResetAt must go through upcomingInstant, not re-implement the guard");

const PARAM = {
    upcomingInstant: "epoch",
    formatResetAt: "epoch",
    formatRenewalDate: "epoch",
    renewalLine: "meter",
    hasRenewalLine: "meter",
    resetLabel: "meter",
    setShowRenewalDates: "on",
};

function makeRoot({ showRenewalDates = false, pluginService = null } = {}) {
    const root = { showRenewalDates, pluginService };
    for (const [name, body] of Object.entries(bodies)) {
        // eslint-disable-next-line no-new-func
        const fn = new Function("root", "Qt", "Date", PARAM[name], body);
        root[name] = arg => fn(root, Qt, QtDate, arg);
    }
    return root;
}

const on = makeRoot({ showRenewalDates: true });
const off = makeRoot({ showRenewalDates: false });

const FUTURE = (NOW + 3 * DAY) / 1000;
const PAST = (NOW - 3600 * SECOND) / 1000;

// ---- 1. the empty-string contract ------------------------------------------

// Every way a renewal instant can be unknown. Each must produce nothing at all
// — the acceptance criterion is that such a bar is indistinguishable from the
// setting being off.
for (const [label, epoch] of [
    ["zero", 0],
    ["negative", -1],
    ["undefined", undefined],
    ["null", null],
    ["empty string", ""],
    ["NaN", NaN],
    ["unparseable", "not-an-epoch"],
    ["already past", PAST],
]) {
    assert.equal(on.upcomingInstant(epoch), null,
        `upcomingInstant must reject a ${label} epoch`);
    assert.equal(on.formatRenewalDate(epoch), "",
        `formatRenewalDate must render nothing for a ${label} epoch`);
    assert.equal(on.renewalLine({ label: "Weekly (7d)", pct: 50, resetAt: epoch }), "",
        `renewalLine must render nothing for a ${label} epoch`);
}

// A meter object that is not there at all, and one that carries no resetAt key
// — the credit-pool ("Credits") shape, which the engines emit with a spend
// amount and no renewal instant of any kind.
assert.equal(on.renewalLine(null), "", "renewalLine must tolerate a null meter");
assert.equal(on.renewalLine(undefined), "", "renewalLine must tolerate a missing meter");
assert.equal(
    on.renewalLine({ label: "Credits", pct: 42, used: 2542, limit: 5000, currency: "USD", detail: "$2542.00 of $5000.00" }),
    "",
    "a credit pool has no renewal epoch and must not gain a renewal line",
);

// ---- 2. off by default means literally nothing renders ---------------------

// The same meter that renders a line when the setting is on.
const liveMeter = { label: "Weekly (7d)", pct: 85, reset: "2d 12h", resetAt: FUTURE };

assert.equal(off.renewalLine(liveMeter), "",
    "with the setting off no bar may gain a renewal line, however good the data is");
assert.notEqual(on.renewalLine(liveMeter), "",
    "with the setting on and a future epoch there must BE a line — otherwise the " +
    "assertions above prove nothing but that the function always returns empty");

// ---- 3. what the line actually says ----------------------------------------

const line = on.renewalLine(liveMeter);
assert.match(line, /^Renews /, "the renewal line must name what the date is for");
assert.match(line, /2026/, "the renewal line is the unabbreviated form and must carry the year");
assert.match(line, /10 Aug/, "the renewal line must carry the absolute day, not only a weekday");
assert.match(line, /12:00/, "the renewal line must carry the wall-clock time");

// The documented difference between the two formatters. The compact column
// shares its row with a progress bar, so it always drops the year.
const compact = on.formatResetAt(FUTURE);
assert.notEqual(compact, "", "a future epoch must still produce a compact instant");
assert.doesNotMatch(compact, /2026/,
    "formatResetAt must stay abbreviated — it always drops the year");

// ---- 4. the two sites that must not print the same instant twice -----------

// Full-detail cards: with the renewal line on, resetLabel keeps the countdown
// (which the renewal line does not carry) and drops the abbreviated instant
// (which it does).
const labelOff = off.resetLabel(liveMeter);
assert.match(labelOff, /Resets in 2d 12h/, "with the setting off the countdown still shows");
assert.match(labelOff, new RegExp(compact.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
    "with the setting off resetLabel still carries the abbreviated instant");

const labelOn = on.resetLabel(liveMeter);
assert.equal(labelOn, "Resets in 2d 12h",
    "with the renewal line on, resetLabel must drop the instant the renewal line already spells out");

// Degrading correctly matters more than the happy path: when there is no usable
// epoch there is no renewal line either, so the countdown must survive
// untouched rather than being suppressed for a line that never renders.
const staleMeter = { label: "Session (5h)", pct: 10, reset: "4h 2m", resetAt: PAST };
assert.equal(on.renewalLine(staleMeter), "", "a stale epoch produces no renewal line");
assert.equal(on.resetLabel(staleMeter), off.resetLabel(staleMeter),
    "with no renewal line to defer to, resetLabel must render exactly as it does with the setting off");
assert.equal(on.resetLabel(staleMeter), "Resets in 4h 2m",
    "the countdown must survive when the absolute instant is unusable");

assert.equal(on.resetLabel(null), "", "resetLabel must tolerate a null meter");

// One rule, one predicate. Both suppression sites must ask hasRenewalLine — a
// site keyed off the global showRenewalDates instead would drop the instant for
// a meter that renders no renewal line, losing it outright.
assert.equal(on.hasRenewalLine(liveMeter), true, "a meter with a future epoch has a renewal line");
assert.equal(on.hasRenewalLine(staleMeter), false, "a stale epoch means no renewal line to defer to");
assert.equal(off.hasRenewalLine(liveMeter), false, "with the setting off nothing has a renewal line");
assert.match(bodies.resetLabel, /hasRenewalLine\(meter\)/,
    "resetLabel must suppress on the meter-local predicate, not on the global mode");

// ---- 4b. the collapsed row's shape -----------------------------------------

// The functions above are only half the dedupe: the collapsed multi-account row
// does its own suppression in a binding, and no amount of function-level
// assertion can see it. Reverting that binding to the pre-fix
// `formatSpend(...) || formatResetAt(...)` left this suite green, so the exact
// regression this change exists to fix could come back unnoticed. These pin the
// binding shapes instead, scoped to the delegate so an unrelated occurrence
// elsewhere in a 1000-line file cannot satisfy them.

// The Repeater's model line is the unique literal immediately before the
// delegate, so extractBlock lands on the delegate's own braces.
const compactDelegate = extractBlock(source, "model: accountCard.expanded ? [] : accountCard.meters");
assert.match(compactDelegate, /id: compactRow/,
    "extraction must have landed on the collapsed-row delegate");

// A property binding plus any continuation lines, which start with an operator.
function binding(body, prop, what) {
    const m = body.match(new RegExp(`\\n\\s*${prop}:\\s*([^\\n]*(?:\\n\\s*[+\\-?:|&][^\\n]*)*)`));
    assert.ok(m, `expected a ${prop} binding on ${what}`);
    return m[1];
}

// Only the span belonging to each child, so compactRenewal's own bindings
// cannot stand in for compactReset's.
const resetSpan = compactDelegate.slice(
    compactDelegate.indexOf("id: compactReset"), compactDelegate.indexOf("id: compactRenewal"));
const renewalSpan = compactDelegate.slice(compactDelegate.indexOf("id: compactRenewal"));
assert.ok(resetSpan && renewalSpan, "the delegate must still declare compactReset and compactRenewal");

const resetText = binding(resetSpan, "text", "compactReset");
assert.match(resetText, /hasRenewal/,
    "compactReset must defer its instant when the row prints a renewal line — without this, " +
    "the collapsed row shows the same instant twice, once abbreviated and once in full");
assert.match(resetText, /formatSpend/,
    "compactReset must still show a credit pool's amount: a credit pool has no renewal epoch, " +
    "so its amount is never in competition with a renewal line");

// How hasRenewal is DEFINED, not just where it is used. Pinning only the uses
// left a live mutant: redefining the property as `compactRenewal.visible`
// reintroduces the exact effective-visibility dependency the assertions below
// describe, while the height binding still contains the token `hasRenewal` and
// still does not contain `compactRenewal.visible` — so both of them passed.
assert.match(compactDelegate, /readonly property bool hasRenewal:\s*root\.hasRenewalLine\(modelData\)/,
    "hasRenewal must be defined as the shared meter-local predicate; defining it from " +
    "compactRenewal.visible puts effective visibility back into the layout arithmetic " +
    "no matter what the height binding says");

const heightBinding = binding(compactDelegate, "height", "the collapsed row");
assert.match(heightBinding, /hasRenewal/,
    "the row must reserve its extra height on 'is there a renewal string'");
assert.doesNotMatch(heightBinding, /compactRenewal\.visible/,
    "the height must NOT key off Item.visible — that is effective visibility, which would make " +
    "this row's layout arithmetic depend on whether some ancestor happens to be shown");

// The gap is one number in two places; restating it is how the row ends up
// clipped or padded.
assert.match(heightBinding, /renewalGap/,
    "the reserved height must use renewalGap rather than restating the literal");
assert.match(binding(renewalSpan, "anchors\\.topMargin", "compactRenewal"), /renewalGap/,
    "the anchor margin must use the same renewalGap the height reserves");

// The single-line contract, which the base class actively works against:
// StyledText defaults to `wrapMode: Text.WordWrap`, and this element's width is
// bounded by its left/right anchors, so WITHOUT an explicit override a long or
// localized string wraps to a second line — and the height above, which reads
// implicitHeight, quietly grows with it. The default being the wrong one is
// exactly why this needs pinning: removing the override reintroduces the bug
// silently, and nothing else in the suite would notice.
// Only wrapMode is pinned. Eliding is StyledText's own default (ElideRight, the
// line after wrapMode in its declaration), so an overflowing NoWrap line elides
// whether or not this element restates it — asserting the redundant local
// declaration would fail a harmless cleanup while proving nothing extra.
assert.match(renewalSpan, /wrapMode:\s*Text\.NoWrap/,
    "compactRenewal must set wrapMode explicitly to NoWrap — StyledText defaults to " +
    "WordWrap, which makes the collapsed row's single-line height arithmetic wrong");

// The gap is a spacing-scale token, not a raw number: design-language.md § 4
// admits only spacingXXS/XS/S/M/L/XL, and sizes a label↔description gap — which
// is what the renewal line is to the summary row — at spacingXXS.
assert.match(compactDelegate, /readonly property int renewalGap:\s*Theme\.spacing/,
    "renewalGap must come from the spacing scale rather than a hardcoded pixel count");

// ---- 4c. the other two render sites ----------------------------------------

// Acceptance criterion 2 is "EVERY progress bar ... gains a small line below
// it", and the popout draws bars in three places, not one. Section 4b pins only
// the collapsed row, so deleting the renewal StyledText from either full-detail
// card left this suite green while breaking the criterion outright — and the
// nested smoke cannot see it, because it loads the plugin with the setting off.
//
// Same idiom as 4b: extract each delegate by the unique Repeater model line
// immediately preceding it, so a sibling delegate's renewal line cannot satisfy
// another's assertion.
const renderSites = [
    {
        what: "the single-account full-detail card",
        opener: "model: (root.ok && !root.multiAccount) ? root.primaryMeters : []",
        landmark: /id: rowCol/,
    },
    {
        what: "the expanded per-account card",
        opener: "model: accountCard.expanded ? accountCard.meters : []",
        landmark: /modelData\.detail \? modelData\.detail : root\.resetLabel\(modelData\)/,
    },
];

for (const site of renderSites) {
    const delegate = extractBlock(source, site.opener);
    assert.match(delegate, site.landmark, `extraction must have landed on ${site.what}`);

    const at = delegate.search(/text:\s*root\.renewalLine\(modelData\)/);
    assert.notEqual(at, -1,
        `${site.what} must render a renewal line — acceptance criterion 2 covers every ` +
        "progress bar in the popout, not only the collapsed multi-account rows");

    // Scoped to the renewal element itself — the sibling detail/reset line in
    // these cards carries the same visible binding, and would otherwise satisfy
    // this on its own. Rendering unconditionally would put an empty row under
    // every bar with no usable epoch, the "no placeholder" half of the criterion.
    const element = delegate.slice(at, delegate.indexOf("}", at));
    assert.match(element, /visible:\s*text\.length > 0/,
        `${site.what} must hide its renewal line when there is no renewal string`);
}

// ---- 5. the default, and the persisted value -------------------------------

// The property declaration itself, evaluated rather than string-matched: a
// rearrangement that inverts the meaning must fail, not pass.
const declMatch = source.match(/property bool showRenewalDates:\s*(.+)/);
assert.ok(declMatch, "AiUsageWidget.qml must still declare showRenewalDates");
// eslint-disable-next-line no-new-func
const readFlag = new Function("pluginData", `return (${declMatch[1].trim()});`);

// Only a real boolean true turns it on. Everything else — an absent key, a
// persisted string, a truthy number — is off, which is what makes "existing
// users see no change" hold across whatever a settings store round-trips.
for (const stored of [undefined, null, false, 0, 1, "", "false", "true", "1", {}, []]) {
    assert.equal(readFlag({ showRenewalDates: stored }), false,
        `showRenewalDates must read as off for a stored ${JSON.stringify(stored) ?? "undefined"}`);
}
assert.equal(readFlag({}), false, "an absent key must read as off");
assert.equal(readFlag({ showRenewalDates: true }), true, "a real boolean true must turn it on");

// The setter must persist a boolean, not whatever the control handed it —
// otherwise a stored "true" string comes back and reads as off by the rule above.
for (const [given, expected] of [[true, true], [false, false], ["true", false], [1, false], [undefined, false]]) {
    const saved = [];
    const root = makeRoot({
        pluginService: { savePluginData: (id, key, value) => saved.push([id, key, value]) },
    });
    root.setShowRenewalDates(given);
    assert.deepEqual(saved, [["aiUsage", "showRenewalDates", expected]],
        `setShowRenewalDates(${JSON.stringify(given)}) must persist the boolean ${expected}`);
}

// And it must persist ONLY. showRenewalDates is a binding on pluginData;
// assigning to it imperatively destroys that binding, so the instance that was
// clicked stops following pluginDataChanged from then on. The bar runs one
// aiUsage instance per display, so the visible symptom is two bars disagreeing
// about one stored setting — which no amount of round-trip testing on a single
// instance would reveal. The write-through path is what makes assignment
// unnecessary: PluginService.savePluginData updates SettingsData's in-memory
// pluginSettings before it emits pluginDataChanged, and every PluginComponent
// reloads from that.
// Matched against the body with COMMENTS STRIPPED and strings kept. Both
// halves matter, and the first version of this guard got both wrong:
//
//  - Comments stripped, because extractBlock returns the raw source. A comment
//    saying "never assign root.showRenewalDates here" tripped the guard, which
//    is a false failure in the one check standing between us and a real
//    regression — the worst place to have one.
//  - Strings KEPT, because bracket notation is how the assignment comes back
//    past a dot-only pattern. Blanking string literals would turn
//    root["showRenewalDates"] = x into root[""] = x and hide it again. The
//    savePluginData("aiUsage", "showRenewalDates", …) call is not a false
//    match: the pattern requires an `=` after the property reference.
//
// The `=(?!=)` tail is what keeps a legitimate READ — root.showRenewalDates
// === something — from reading as a write.
//
// Not covered, and a static scan cannot cover it: a computed key
// (root[someVar] = …) or an alias. This pins the spellings someone would
// actually reach for, and fails closed on neither.
const setterCode = stripComments(bodies.setShowRenewalDates);
assert.doesNotMatch(
    setterCode,
    /root\s*(?:\.\s*showRenewalDates|\[\s*["']showRenewalDates["']\s*\])\s*=(?!=)/,
    "setShowRenewalDates must not assign to the bound property, in any spelling — persist " +
    "only, and let the pluginData binding carry the new value to every instance");

// No pluginService (the widget can exist before one is wired) must not throw.
// Nothing is persisted and nothing changes: there is no store to write to and
// so no pluginDataChanged to come back. That is the honest outcome of a
// persist-only setter, and better than a local assignment that would look like
// it worked while silently breaking the binding.
const detached = makeRoot({ pluginService: null });
detached.setShowRenewalDates(true);
assert.equal(detached.showRenewalDates, false,
    "with nothing to persist to, the setter must be a no-op rather than clobbering the binding");

// ---- 6. exactly one control, and it exists ---------------------------------

// VGS-67 review: the toggle lives in the popout's gear pane, beside the other
// display-shaping options. A second control for the same key in the file-based
// pane would give two widgets that can disagree about the same stored value.
assert.doesNotMatch(settingsSource, /showRenewalDates/,
    "showRenewalDates belongs to the popout gear pane; a duplicate control in " +
    "AiUsageSettings.qml would write the same key from two places");
assert.match(source, /savePluginData\("aiUsage", "showRenewalDates"/,
    "the gear-pane toggle must persist under the same plugin-data key, so moving " +
    "the control migrates no state");

// And the control has to BE there. The assertion above is satisfied by the
// setter alone, which this test calls itself — so deleting the gear-pane toggle
// outright left the suite green while making the setting unreachable from any
// UI at all, the gear pane now being the only place it lives.
//
// The StyledRect wrapping the gear pane is identified by its visibility
// binding, so this lands on the settings column rather than on some other
// Column in the popout.
const gearPane = extractBlock(source, "visible: popout.settingsOpen");
assert.match(gearPane, /id: settingsCol/, "extraction must have landed on the gear settings pane");

assert.match(gearPane, /VgsToggle\s*\{/,
    "the gear pane must carry a toggle control — without one the setting is unreachable");
assert.match(gearPane, /checked:\s*root\.showRenewalDates/,
    "the gear-pane toggle must reflect the current value, or it can show 'off' while it is on");
assert.match(gearPane, /onToggled:[^\n]*root\.setShowRenewalDates\(/,
    "the gear-pane toggle must write through setShowRenewalDates, which is what coerces " +
    "the stored value to a real boolean");

console.log("ai usage renewal dates: all checks passed");
