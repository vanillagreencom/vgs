#!/usr/bin/env node
// Table-driven checks for vgs.polkit's pure decisions, PolkitModel.js: the
// title, prompt, identity and note the prompt draws from the agent's
// authentication flow, when its field and accept action answer, which
// flows closing the prompt cancels, and the agent status the service
// publishes. Expected values are written by hand. Controls edit a copy of
// the module, one rule each, and require this suite to fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.polkit", "PolkitModel.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message || "");

// A flow as the agent holds one while PAM waits for a password, with
// FIELDS over it.
const flow = fields => Object.assign({
    message: "Authentication is required to change the system time.",
    inputPrompt: "Password: ",
    isResponseRequired: true,
    responseVisible: false,
    supplementaryMessage: "",
    supplementaryIsError: false,
    failed: false,
    isCompleted: false,
    isCancelled: false,
    selectedIdentity: { string: "alice", displayName: "Alice Liddell", isGroup: false }
}, fields);

function verify(model) {
    const TITLES = [
        ["pkexec names its program", "Authentication is needed to run `/usr/bin/true' as the super user", "Authorize running /usr/bin/true"],
        ["pkexec with straight quotes", "Authentication is required to run '/usr/bin/id' as the user bob", "Authorize running /usr/bin/id"],
        ["another action keeps the default", "Authentication is required to change the system time.", "Authentication required"],
        ["no message", "", "Authentication required"]
    ];
    for (const [label, message, want] of TITLES) assert.equal(model.titleOf(message), want, label);

    const PROMPTS = [["Password: ", "Password"], ["PIN:", "PIN"], ["", "Password"], ["  :  ", "Password"], ["Token code", "Token code"]];
    for (const [text, want] of PROMPTS) assert.equal(model.promptOf(text), want, JSON.stringify(text));

    const IDENTITIES = [
        ["a user's display name", { string: "alice", displayName: "Alice Liddell", isGroup: false }, "Alice Liddell"],
        ["a user with no display name", { string: "alice", displayName: "", isGroup: false }, "alice"],
        ["a group", { string: "wheel", displayName: "wheel", isGroup: true }, "Group wheel"],
        ["no identity", null, ""]
    ];
    for (const [label, identity, want] of IDENTITIES) assert.equal(model.identityOf(identity), want, label);

    assert.equal(model.viewOf(null), null, "no flow draws nothing");
    same(model.viewOf(flow({})), {
        title: "Authentication required", message: "Authentication is required to change the system time.",
        identity: "Alice Liddell", prompt: "Password", echo: false, inputEnabled: true, waiting: false, note: null
    }, "a flow waiting for the password");
    const VIEWS = [
        ["a submitted response waits", { isResponseRequired: false, inputPrompt: "" }, { inputEnabled: false, waiting: true }],
        ["a visible response echoes", { responseVisible: true }, { echo: true }],
        ["PAM's error shows in danger", { supplementaryMessage: "Account locked", supplementaryIsError: true }, { note: { text: "Account locked", tone: "danger" } }],
        ["PAM's information shows as a hint", { supplementaryMessage: "Touch the key" }, { note: { text: "Touch the key", tone: "info" } }],
        ["a failed attempt says so", { failed: true }, { note: { text: "Authentication failed. Try again.", tone: "danger" } }],
        ["PAM's own message wins over the failed note", { failed: true, supplementaryMessage: "2 attempts left", supplementaryIsError: true }, { note: { text: "2 attempts left", tone: "danger" } }]
    ];
    for (const [label, fields, want] of VIEWS) {
        const view = model.viewOf(flow(fields));
        for (const key of Object.keys(want)) same(view[key], want[key], `${label}: ${key}`);
    }

    const ok = model.agentStatus(true), warning = model.agentStatus(false);
    const CHANGES = [
        ["the first state publishes", null, warning, true],
        ["the same state again does not", warning, model.agentStatus(false), false],
        ["a new state publishes", warning, ok, true],
        ["no state publishes nothing", ok, null, false]
    ];
    for (const [label, previous, next, want] of CHANGES) assert.equal(model.statusChanged(previous, next), want, label);

    const CANCELLABLE = [["a live flow", flow({}), true], ["no flow", null, false], ["a completed flow", flow({ isCompleted: true }), false], ["a cancelled flow", flow({ isCancelled: true }), false]];
    for (const [label, value, want] of CANCELLABLE) assert.equal(model.cancellable(value), want, label);

    const STATES = [["a registered agent", true, "ok"], ["an agent polkitd refused", false, "warning"]];
    for (const [label, registered, tone] of STATES) {
        const state = model.agentStatus(registered);
        assert.equal(state.tone, tone, label);
        assert.ok(typeof state.text === "string" && state.text.length > 0 && state.text.length <= 200, `${label}: a state text fits the status type`);
    }
}

verify(load(file));

const CONTROLS = [
    ["the pkexec program names the title", 'return match ? "Authorize running " + match[1] : DEFAULT_TITLE;', "return DEFAULT_TITLE;"],
    ["the prompt drops its colon", ".replace(/[\\s:]+$/, \"\")", ".replace(/$^/, \"\")"],
    ["a group reads as a group", "if (identity.isGroup === true) return", "if (false) return"],
    ["a display name wins over the login name", 'return display !== "" ? display : name;', "return name;"],
    ["PAM's error message takes the danger tone", 'flow.supplementaryIsError === true ? "danger" : "info"', '"info"'],
    ["a failed attempt shows a note", "if (flow.failed === true) return", "if (false) return"],
    ["the field waits while PAM works", "inputEnabled: required,", "inputEnabled: true,"],
    ["the echo follows responseVisible", "echo: flow.responseVisible === true,", "echo: false,"],
    ["no flow draws nothing", "if (flow === null || flow === undefined) return null;", "if (flow === undefined) return null;"],
    ["a cancelled flow is not cancelled again", " && flow.isCancelled !== true", ""],
    ["a completed flow is not cancelled", " && flow.isCompleted !== true", ""],
    ["an unchanged state is not published again", "return previous === null || previous.tone !== next.tone || previous.text !== next.text;", "return true;"],
    ["no state is never published", "    if (next === null) return false;\n", ""],
    ["an unregistered agent warns", 'if (registered === true) return { tone: "ok"', 'if (true) return { tone: "ok"']
];
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "test-polkit-model-")));
try {
    const source = fs.readFileSync(file, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length - 1, 1, `control pattern occurs once: ${label}`);
        const mutant = path.join(scratch, "PolkitModel.js");
        fs.writeFileSync(mutant, source.replace(needle, replacement));
        let red = false;
        try { verify(load(mutant)); } catch (e) { red = true; }
        assert.equal(red, true, `control passed the suite: ${label}`);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}

console.log(`test-polkit-model: ok controls=${CONTROLS.length}`);
