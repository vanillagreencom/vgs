#!/usr/bin/env node

// Test grant-confirmation decisions and modal defaults using repository source only.
// Passwordless sudo persists, and an existing credential or external rule can make a terminal
// prompt provide no additional confirmation. The modal therefore requires explicit user action.

"use strict";

const test = require("node:test");
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

const extracted = new Function(
    `${match[1]}\nreturn { grantDecision, confirmOutcome, isDirectActivation };`
)();
const { grantDecision, confirmOutcome, isDirectActivation } = extracted;

const ASK = false;
const SKIP = true;

test("grantDecision confirms or grants a click on a disabled toggle, revokes a click on an enabled one, and ignores every other origin", () => {
    for (const [origin, enabled, skip, expected, why] of [
        ["click", false, ASK, "confirm", "a click on a disabled toggle must open the confirmation modal, never grant; repeated clicks keep asking"],
        ["click", false, SKIP, "grant", "with 'don't ask me again' stored, a click must grant without prompting"],
        ["click", true, ASK, "revoke", "revoking must never be confirmed — it only ever removes privilege"],
        ["click", true, SKIP, "revoke", "the suppression flag must have no say over revocation"],
        ["hover", false, ASK, "ignore", "a hover activation must not even open the modal"],
        ["hover", false, SKIP, "ignore", "a hover activation must not grant even with confirmation suppressed"],
        ["hover", true, ASK, "ignore", "a hover activation must not revoke either"],
        ["ipc", false, ASK, "ignore", "the IPC widget toggle must not open the modal"],
        ["ipc", false, SKIP, "ignore", "nor grant with confirmation suppressed"],
        ["ipc", true, ASK, "ignore", "nor revoke"],
        [undefined, false, ASK, "ignore", "a missing origin must not open the modal"],
        [undefined, false, SKIP, "ignore", "nor grant"],
        [undefined, true, ASK, "ignore", "nor revoke"],
        ["", false, ASK, "ignore", "an empty origin must not open the modal"],
        ["", false, SKIP, "ignore", "nor grant"],
        ["", true, ASK, "ignore", "nor revoke"],
        ["Click", false, ASK, "ignore", "the origin check must not be case-insensitive by accident"],
        ["Click", false, SKIP, "ignore", "nor grant"],
        ["Click", true, ASK, "ignore", "nor revoke"]
    ]) {
        assert.equal(grantDecision(origin, enabled, skip), expected,
            `${JSON.stringify(origin)} enabled=${enabled} skip=${skip}: ${why}`);
    }
});

test("isDirectActivation is true for a real press only", () => {
    for (const [origin, expected, why] of [
        ["click", true, "a real press must count as direct activation"],
        ["hover", false, "hover must not count as direct activation"],
        [undefined, false, "a caller passing no origin must not count"],
        ["", false, "an empty origin must not count"],
        ["Click", false, "the origin check must not be case-insensitive by accident"],
        ["ipc", false, "the IPC widget toggle (vshell ipc call bar toggle sudoToggle) must not grant either"]
    ]) {
        assert.equal(isDirectActivation(origin), expected, why);
    }
});

test("confirmOutcome grants only on confirm, remembers the opt-out only with a real true, and fails closed otherwise", () => {
    for (const [action, box, expected, why] of [
        ["confirm", false, { grant: true, skipFuture: false }, "confirming with the box unticked grants once and keeps asking"],
        ["confirm", true, { grant: true, skipFuture: true }, "confirming with the box ticked grants and stops asking"],
        ["cancel", true, { grant: false, skipFuture: false }, "ticking the box and then cancelling must change nothing at all"],
        ["cancel", false, { grant: false, skipFuture: false }, "cancelling must not grant"],
        ["dismiss", true, { grant: false, skipFuture: false }, "an unrecognised action must fail closed"],
        [undefined, true, { grant: false, skipFuture: false }, "a missing action must fail closed"],
        ["confirm", "yes", { grant: true, skipFuture: false }, "the checkbox must be a real true, not merely truthy"]
    ]) {
        assert.deepEqual(confirmOutcome(action, box), expected, why);
    }
});

// Reject pointer-gesture state that could provide a second path to a grant.

test("the pointer gesture is gone and only the modal's confirmed signal starts a grant", () => {
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
});

test("the modal defaults to Cancel, starts the opt-out unticked, declines on background and Escape, and states the rule is permanent", () => {
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
});

// Check dismissal behavior as well as selected defaults so close and background paths cannot confirm.

test("every dismissal path declines and exactly one control can confirm", () => {
    assert.ok(/function _finish\(button\)\s*\{[\s\S]*?if \(grant\)\s*root\.confirmed\(skipFuture\);\s*else\s*root\.cancelled\(\);/.test(modalSource),
        "cancel paths must emit cancelled rather than confirmed");
    assert.ok(/Qt\.Key_Return:[\s\S]*?Qt\.Key_Enter:[\s\S]*?root\._finish\(root\.selectedButton\)/.test(modalSource),
        "Return and Enter must invoke the selected control, not a hardcoded one");
    assert.ok(/VgsActionButton\s*\{[\s\S]*?iconName:\s*"close"[\s\S]*?onClicked:\s*root\._finish\(root\.cancelButton\)/.test(modalSource),
        "the close control must decline");
    // Only the grant control may identify confirmButton; other paths retain explicit or selected cancel behavior.
    assert.equal((modalSource.match(/_finish\(root\.confirmButton\)/g) || []).length, 1,
        "exactly one control may confirm; a second confirm call site is a second grant path");
    assert.equal((modalSource.match(/root\.confirmed\(/g) || []).length, 1,
        "the grant signal must have exactly one emitter, inside _finish");
});

test("the skip setting is declared false in the spec and the data", () => {
    const specSource = fs.readFileSync(SETTINGS_SPEC, "utf8");
    assert.ok(/sudoToggleSkipGrantConfirm:\s*\{\s*def:\s*false\s*\}/.test(specSource),
        "SettingsSpec must declare sudoToggleSkipGrantConfirm defaulting to false");
    const settingsDataSource = fs.readFileSync(SETTINGS_DATA, "utf8");
    assert.ok(/property bool sudoToggleSkipGrantConfirm:\s*false/.test(settingsDataSource),
        "SettingsData must carry the same default, so a fresh profile is asked");
});

test("the plugin ships a settings pane with the capability to render it", () => {
    const manifest = JSON.parse(fs.readFileSync(PLUGIN_MANIFEST, "utf8"));
    assert.equal(manifest.settings, "./SudoToggleSettings.qml",
        "the plugin must ship a settings pane, so the opt-out can be undone");
    assert.ok(fs.existsSync(path.join(path.dirname(PLUGIN_MANIFEST), "SudoToggleSettings.qml")),
        "the declared settings pane must exist");
    // The settings UI requires settings_write capability to render.
    assert.ok((manifest.permissions || []).includes("settings_write"),
        "the settings pane needs settings_write or it renders an error instead");
});
