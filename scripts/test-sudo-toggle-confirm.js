#!/usr/bin/env node

// Exercises the sudoToggle grant-confirmation gate.
//
// The gate exists because enabling passwordless sudo is permanent, has no
// expiry, and where sudo already does not prompt (a foreign wheel NOPASSWD
// rule, a live credential cache) the terminal gives visibility but no
// authentication — so this is the only real gate in that configuration.
//
// Since VGS-55 the gate is a modal (SudoGrantConfirmModal), not a toast plus a
// pointer gesture. What this file pins is therefore two things:
//   * the widget's routing decisions, extracted verbatim from the shipped QML
//     between its BEGIN/END CONFIRM DECISION markers, so this tests the real
//     source rather than a re-implementation of it; and
//   * the modal's safety-critical *defaults*, asserted against its source,
//     because bundled plugins and modals get no runtime coverage from
//     `qml-smoke.sh --nested` (VGS-19).
//
// Everything here reads files from this repo. It must never depend on ambient
// host state (VGS-42: a sudo-toggle check once passed only because a terminal
// emulator happened to be installed, and was silently unverified in CI).

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(
    repoRoot, "config", "vshell", "plugins", "sudoToggle", "SudoToggleWidget.qml"
);
const MODAL = path.join(repoRoot, "quickshell", "vshell", "Modals", "SudoGrantConfirmModal.qml");
const PLUGIN_MANIFEST = path.join(
    repoRoot, "config", "vshell", "plugins", "sudoToggle", "plugin.json"
);
const SETTINGS_SPEC = path.join(
    repoRoot, "quickshell", "vshell", "Common", "settings", "SettingsSpec.js"
);
const SETTINGS_DATA = path.join(repoRoot, "quickshell", "vshell", "Common", "SettingsData.qml");

const source = fs.readFileSync(WIDGET, "utf8");
const modalSource = fs.readFileSync(MODAL, "utf8");
const match = source.match(/\/\/ BEGIN CONFIRM DECISION\n([\s\S]*?)\/\/ END CONFIRM DECISION/);
assert.ok(match, "SudoToggleWidget.qml must carry the CONFIRM DECISION markers");

// The extracted text is plain JavaScript with no QML API use, so it evaluates
// as ordinary functions.
const extracted = new Function(
    `${match[1]}\nreturn { grantDecision, confirmOutcome, isDirectActivation };`
)();
const { grantDecision, confirmOutcome, isDirectActivation } = extracted;

const ASK = false;   // SettingsData.sudoToggleSkipGrantConfirm
const SKIP = true;

// --- Granting is never immediate unless the user opted out ------------------

assert.equal(grantDecision("click", false, ASK), "confirm",
    "a click on a disabled toggle must open the confirmation modal, never grant");
assert.equal(grantDecision("click", false, SKIP), "grant",
    "with 'don't ask me again' stored, a click must grant without prompting");

// A second click while the modal is up asks again rather than confirming: the
// widget has no armed state left to satisfy, so nothing about clicking the pill
// repeatedly can complete a grant.
assert.equal(grantDecision("click", false, ASK), "confirm",
    "repeated clicks must keep asking; a double-click must never confirm");

// --- Revoking stays unprompted ----------------------------------------------

assert.equal(grantDecision("click", true, ASK), "revoke",
    "revoking must never be confirmed — it only ever removes privilege");
assert.equal(grantDecision("click", true, SKIP), "revoke",
    "the suppression flag must have no say over revocation");

// --- Only a real click may act (VGS-11 round 4) ------------------------------
//
// BarHoverController calls triggerHoverPopout on every PluginComponent;
// PluginComponent.triggerPopout forwards a zero-argument pillClickAction. So a
// pointer merely crossing the bar used to reach toggle(). A modal cannot be
// confirmed by traversal, but hover must not open it, and — critically — with
// confirmation suppressed hover would otherwise complete a grant outright.

assert.equal(isDirectActivation("click"), true, "a real press must count as direct activation");
assert.equal(isDirectActivation("hover"), false, "hover must not count as direct activation");
assert.equal(isDirectActivation(undefined), false, "a caller passing no origin must not count");
assert.equal(isDirectActivation(""), false, "an empty origin must not count");
assert.equal(isDirectActivation("Click"), false, "the origin check must not be case-insensitive by accident");
assert.equal(isDirectActivation("ipc"), false,
    "the IPC widget toggle (vshell ipc call bar toggle sudoToggle) must not grant either");

for (const origin of ["hover", "ipc", undefined, "", "Click"]) {
    assert.equal(grantDecision(origin, false, ASK), "ignore",
        `a ${JSON.stringify(origin)} activation must not even open the modal`);
    assert.equal(grantDecision(origin, false, SKIP), "ignore",
        `a ${JSON.stringify(origin)} activation must not grant even with confirmation suppressed`);
    assert.equal(grantDecision(origin, true, ASK), "ignore",
        `a ${JSON.stringify(origin)} activation must not revoke either`);
}

// --- "Don't ask me again" is only honoured by an actual confirmation ---------

assert.deepEqual(confirmOutcome("confirm", false), { grant: true, skipFuture: false },
    "confirming with the box unticked grants once and keeps asking");
assert.deepEqual(confirmOutcome("confirm", true), { grant: true, skipFuture: true },
    "confirming with the box ticked grants and stops asking");
assert.deepEqual(confirmOutcome("cancel", true), { grant: false, skipFuture: false },
    "ticking the box and then cancelling must change nothing at all");
assert.deepEqual(confirmOutcome("cancel", false), { grant: false, skipFuture: false },
    "cancelling must not grant");
// Anything that is not an explicit confirmation is a decline. A future caller
// passing a new action name must fail closed.
assert.deepEqual(confirmOutcome("dismiss", true), { grant: false, skipFuture: false },
    "an unrecognised action must fail closed");
assert.deepEqual(confirmOutcome(undefined, true), { grant: false, skipFuture: false },
    "a missing action must fail closed");
assert.deepEqual(confirmOutcome("confirm", "yes"), { grant: true, skipFuture: false },
    "the checkbox must be a real true, not merely truthy");

// --- The gesture and its state are gone --------------------------------------
//
// The point of VGS-55 is that the pointer heuristics were replaced, not
// supplemented. Leaving any of them behind would resurrect a hidden second path
// to a grant.

for (const dead of ["_armedAt", "_pointerLeftSinceArm", "confirmMinMs", "confirmWindowMs", "confirmDecision"]) {
    assert.equal(source.includes(dead), false,
        `${dead} belongs to the replaced pointer gesture and must not survive in the widget`);
}
assert.equal(/Move the pointer off/i.test(source), false,
    "the pointer-gesture toast must be gone");
assert.ok(/SudoGrantConfirmModal\s*\{/.test(source),
    "the widget must raise the confirmation modal");
assert.ok(/onConfirmed:/.test(source),
    "only the modal's confirmed signal may start a grant");

// --- Modal defaults that carry the safety --------------------------------------

assert.ok(/property int selectedButton:\s*cancelButton/.test(modalSource),
    "Cancel must be the default-focused control, never the destructive one");
assert.ok(/readonly property int cancelButton:\s*0/.test(modalSource)
    && /readonly property int confirmButton:\s*1/.test(modalSource),
    "the button indices the default refers to must be declared");
assert.ok(/root\.dontAskAgain = false;/.test(modalSource),
    "'don't ask me again' must start unticked on every prompt");
assert.ok(/root\.selectedButton = root\.cancelButton;/.test(modalSource),
    "each prompt must reset the selection back to Cancel");
assert.ok(/onBackgroundClicked:\s*root\._finish\(root\.cancelButton\)/.test(modalSource),
    "a background click must decline");
assert.ok(/Qt\.Key_Escape:\s*\n\s*root\._finish\(root\.cancelButton\);/.test(modalSource),
    "Escape must decline");
assert.ok(/permanent NOPASSWD rule/.test(modalSource) && /no expiry/.test(modalSource),
    "the modal must state that the rule is permanent and has no expiry");
assert.ok(/Don't ask me again/.test(modalSource),
    "the modal must offer the opt-out the issue asks for");

// --- The suppression flag is a normal, resettable setting ---------------------

const specSource = fs.readFileSync(SETTINGS_SPEC, "utf8");
assert.ok(/sudoToggleSkipGrantConfirm:\s*\{\s*def:\s*false\s*\}/.test(specSource),
    "SettingsSpec must declare sudoToggleSkipGrantConfirm defaulting to false");
const settingsDataSource = fs.readFileSync(SETTINGS_DATA, "utf8");
assert.ok(/property bool sudoToggleSkipGrantConfirm:\s*false/.test(settingsDataSource),
    "SettingsData must carry the same default, so a fresh profile is asked");

const manifest = JSON.parse(fs.readFileSync(PLUGIN_MANIFEST, "utf8"));
assert.equal(manifest.settings, "./SudoToggleSettings.qml",
    "the plugin must ship a settings pane, so the opt-out can be undone");
assert.ok(fs.existsSync(path.join(path.dirname(PLUGIN_MANIFEST), "SudoToggleSettings.qml")),
    "the declared settings pane must exist");
// PluginSettings refuses to render without settings_write.
assert.ok((manifest.permissions || []).includes("settings_write"),
    "the settings pane needs settings_write or it renders an error instead");

console.log("sudoToggle confirmation gate checks passed.");
