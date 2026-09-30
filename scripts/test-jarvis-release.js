#!/usr/bin/env node
// Synthetic release contract from the Jarvis plan. No vendor protocol.
"use strict";
const { assert, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Policy.js");
const Policy = require(file);

world(() => {
    const local = { kind: "local", provider: "local-speech", account: "" };
    const remote = { kind: "network", provider: "brain", account: "fixture", origin: "https://brain.example" };
    const loopback = { ...remote, origin: "http://127.0.0.1:11434" };
    const cloudSpeech = { ...remote, provider: "voice", origin: "https://voice.example" };
    const sources = ["speech", "desktop", "clipboard", "file", "screen", "web", "command", "agent"];
    const sets = [
        ["local", loopback, [local]],
        ["cloud-brain", remote, [local]],
        ["cloud-speech", loopback, [cloudSpeech]],
        ["both", remote, [local, cloudSpeech]]
    ];
    const select = (logic, profile = "standard", cloudVision = "ask", brain = remote, speech = [cloudSpeech],
        conversation = "conversation") => logic.recipients({ conversation, profile, cloudVision, brain, speech });
    let cases = 0;
    function cell(logic, profile, vision, name, brain, speech, source, granted) {
        const recipients = select(logic, profile, vision, brain, speech);
        const value = logic.item("PRIVATE original " + source, [source]);
        const grants = granted ? [{ recipients, labels: [source] }] : [];
        let kind = "send";
        if (name !== "local" && source === "screen") {
            if (vision === "never") kind = "withhold";
            else if (vision === "ask" && !granted) kind = "ask";
        } else if (name !== "local" && !["speech", "desktop"].includes(source) && profile !== "trusted" && !granted) kind = "ask";
        const result = logic.release(value, recipients, grants);
        assert.equal(result.kind, kind, [profile, vision, name, source, granted].join(" "));
        if (kind === "send") assert.equal(result.content, value.content);
        else {
            assert.equal(result.content, "[withheld: " + (source === "file" ? "file text" : source + " content") + "]");
            assert.equal(JSON.stringify(result).includes("PRIVATE"), false, "no hidden original");
        }
        cases++;
    }
    for (const profile of ["cautious", "standard", "trusted"])
        for (const vision of ["ask", "allow", "never"])
            for (const [name, brain, speech] of sets)
                for (const source of sources)
                    for (const granted of [false, true]) cell(Policy, profile, vision, name, brain, speech, source, granted);

    const selected = select(Policy);
    const fileText = Policy.item("PRIVATE file", ["file"]);
    assert.deepEqual(Policy.release(fileText, selected), { kind: "ask", content: "[withheld: file text]", labels: ["file"], needed: ["file"] });
    assert.equal(Policy.release(fileText, selected, [{ recipients: selected, labels: ["file"] }]).kind, "send");
    assert.equal(Policy.release(fileText, selected, [{ recipients: selected, labels: ["web"] }]).kind, "ask");
    const contributing = sources.map(source => Policy.item("PRIVATE " + source, [source]));
    const combined = Policy.summary("PRIVATE compressed text", contributing);
    assert.deepEqual(combined.labels, sources);
    const nested = Policy.summary("PRIVATE nested", [Policy.summary("prior", contributing.slice(0, 4)), ...contributing.slice(4)]);
    assert.deepEqual(nested.labels, sources, "recursive summaries retain all labels");
    const grantedWithoutScreen = [{ recipients: selected, labels: sources.filter(source => source !== "screen") }];
    assert.deepEqual(Policy.release(combined, selected, grantedWithoutScreen),
        { kind: "ask", content: "[withheld: speech content, desktop content, clipboard content, file text, screen content, web content, command content, agent content]", labels: sources, needed: ["screen"] });
    const bytes = Buffer.from("PRIVATE image");
    const labelled = Policy.item(bytes, ["screen"]);
    bytes.fill(0);
    assert.equal(labelled.content.toString(), "PRIVATE image", "producer buffer is copied");
    assert.equal(Policy.release(labelled, select(Policy, "trusted", "never")).content, "[withheld: screen content]");

    // New sets invalidate grants. Ending the old net owner and dropping its
    // context belongs to the session, not to this pure judge.
    for (const next of [
        { brain: { ...remote, provider: "other" } },
        { brain: { ...remote, account: "other" } },
        { brain: { ...remote, origin: "https://other.example" } },
        { speech: [{ ...cloudSpeech, account: "other" }] },
        { profile: "cautious" },
        { conversation: "next" },
        {}
    ]) {
        const fresh = Policy.recipients({ ...selected, ...next });
        assert.equal(Policy.release(fileText, fresh, [{ recipients: selected, labels: ["file"] }]).kind, "ask");
    }
    remote.account = "changed";
    assert.equal(selected.brain.account, "fixture", "recipient snapshot does not borrow producer data");
    assert.ok(Object.isFrozen(selected) && Object.isFrozen(selected.brain) && Object.isFrozen(selected.speech));

    const invalid = [
        ["content", () => Policy.item({}, ["speech"]), "content"],
        ["labels-empty", () => Policy.item("", []), "labels"],
        ["labels-unknown", () => Policy.item("", ["unknown"]), "labels"],
        ["summary-empty", () => Policy.summary("", []), "summary"],
        ["profile", () => select(Policy, "unknown"), "context"],
        ["vision", () => select(Policy, "standard", "unknown"), "context"],
        ["conversation", () => select(Policy, "standard", "ask", remote, [local], ""), "context"],
        ["speech", () => select(Policy, "standard", "ask", remote, []), "speech-recipients"],
        ["recipient", () => select(Policy, "standard", "ask", { ...remote, kind: "unknown" }), "recipient"],
        ["local-origin", () => select(Policy, "standard", "ask", { ...local, origin: remote.origin }), "local-origin"],
        ["origin", () => select(Policy, "standard", "ask", { ...remote, origin: remote.origin + "/path" }), "recipient-origin"],
        ["set", () => Policy.release(fileText, { ...selected }), "recipient-set"],
        ["grants", () => Policy.release(fileText, selected, null), "grants"],
        ["grant-context", () => Policy.release(fileText, selected, [{ recipients: {}, labels: ["file"] }]), "grant-context"],
        ["grant-label", () => Policy.release(fileText, selected, [{ recipients: selected, labels: ["unknown"] }]), "labels"]
    ];
    for (const [name, run, key] of invalid) assert.throws(run, { message: "jarvis: release=" + key }, name);

    let controls = 0;
    function control(name, needle, replacement, check) { mutant(file, name, needle, replacement, check); controls++; }
    control("summary-labels", "items.flatMap(value => labels(value.labels))", "items.flatMap(value => labels(value.labels)).slice(0, 1)",
        logic => assert.deepEqual(logic.summary("summary", contributing).labels, sources));
    control("label-inventory", "!value.every(source => SOURCES.includes(source))", "false",
        logic => assert.throws(() => logic.item("", ["unknown"]), { message: "jarvis: release=labels" }));
    control("empty-labels", "value.length === 0", "false",
        logic => assert.throws(() => logic.item("", []), { message: "jarvis: release=labels" }));
    control("item-copy", "Buffer.from(content)", "content",
        logic => { const bytes = Buffer.from("before"); const value = logic.item(bytes, ["screen"]); bytes.fill(0);
            assert.equal(value.content.toString(), "before"); });
    control("content-shape", 'typeof content !== "string" && !(content instanceof Uint8Array)', "false",
        logic => assert.throws(() => logic.item({}, ["speech"]), { message: "jarvis: release=content" }));
    control("empty-summary", "!Array.isArray(items) || items.length === 0", "false",
        logic => assert.throws(() => logic.summary("", []), { message: "jarvis: release=summary" }));
    control("context-profile", "!Object.hasOwn(PROFILES, profile)", "false",
        logic => assert.throws(() => select(logic, "unknown"), { message: "jarvis: release=context" }));
    control("context-vision", '!["ask", "allow", "never"].includes(cloudVision)', "false",
        logic => assert.throws(() => select(logic, "standard", "unknown"), { message: "jarvis: release=context" }));
    control("context-conversation", 'typeof conversation !== "string" || conversation === ""', "false",
        logic => assert.throws(() => select(logic, "standard", "ask", remote, [local], ""), { message: "jarvis: release=context" }));
    control("missing-speech", "!Array.isArray(speech) || speech.length === 0", "false",
        logic => assert.throws(() => select(logic, "standard", "ask", remote, []), { message: "jarvis: release=speech-recipients" }));
    control("recipient-kind", '!["local", "network"].includes(value.kind)', "false",
        logic => assert.throws(() => select(logic, "standard", "ask", { ...remote, kind: "unknown" }), { message: "jarvis: release=recipient" }));
    control("local-origin", "if (value.origin !== undefined)", "if (false)",
        logic => assert.throws(() => select(logic, "standard", "ask", { ...local, origin: remote.origin }), { message: "jarvis: release=local-origin" }));
    control("origin-identity", "if (value.origin !== target.origin)", "if (false)",
        logic => assert.throws(() => select(logic, "standard", "ask", { ...remote, origin: remote.origin + "/path" }), { message: "jarvis: release=recipient-origin" }));
    control("registered-set", "if (!recipientSets.has(value))", "if (false)",
        logic => { const set = select(logic); assert.throws(() => logic.release(fileText, { ...set }), { message: "jarvis: release=recipient-set" }); });
    control("recipient-copy", "account: value.account, origin: target.origin", "account: 'wrong', origin: target.origin",
        logic => assert.equal(select(logic).brain.account, "changed"));
    control("grant-array", "if (!Array.isArray(grants))", "if (false)",
        logic => assert.throws(() => logic.release(fileText, select(logic), null), { message: "jarvis: release=grants" }));
    control("grant-context", "!grant || !recipientSets.has(grant.recipients)", "false",
        logic => assert.throws(() => logic.release(fileText, select(logic), [{ recipients: {}, labels: ["file"] }]), { message: "jarvis: release=grant-context" }));
    control("grant-labels", "labels(grant.labels);", "void grant.labels;",
        logic => { const set = select(logic); assert.throws(() => logic.release(fileText, set, [{ recipients: set, labels: ["unknown"] }]), { message: "jarvis: release=labels" }); });
    control("grant-scope", "grant.recipients === selected &&", "",
        logic => { const old = select(logic); assert.equal(logic.release(fileText, select(logic),
            [{ recipients: old, labels: ["file"] }]).kind, "ask"); });
    control("grant-source", "grant.labels.includes(source)", "true",
        logic => { const set = select(logic); assert.equal(logic.release(fileText, set,
            [{ recipients: set, labels: ["web"] }]).kind, "ask"); });
    control("whole-set", "[selectedBrain, ...selectedSpeech].every", "[selectedBrain].every",
        logic => cell(logic, "standard", "ask", "cloud-speech", loopback, [cloudSpeech], "file", false));
    control("local-send", 'if (selected.offline) return { kind: "send", ...current };', 'if (false) return { kind: "send", ...current };',
        logic => cell(logic, "standard", "never", "local", loopback, [local], "screen", false));
    for (const source of ["speech", "desktop"])
        control("provider-" + source, `source === "${source}"`, "false",
            logic => cell(logic, "standard", "ask", "both", remote, [cloudSpeech], source, false));
    control("screen-never", 'selected.cloudVision === "never"', "false",
        logic => cell(logic, "trusted", "never", "both", remote, [cloudSpeech], "screen", true));
    control("screen-allow", 'source === "screen" && selected.cloudVision === "allow"', "false",
        logic => cell(logic, "standard", "allow", "both", remote, [cloudSpeech], "screen", false));
    control("screen-ask-trusted", 'source !== "screen" && selected.profile === "trusted"', 'selected.profile === "trusted"',
        logic => cell(logic, "trusted", "ask", "both", remote, [cloudSpeech], "screen", false));
    control("trusted-other", 'selected.profile === "trusted"', "false",
        logic => cell(logic, "trusted", "ask", "both", remote, [cloudSpeech], "file", false));
    control("withheld-marker", 'kind: "withhold", content: marker, labels: current.labels', 'kind: "withhold", content: current.content, labels: current.labels',
        logic => { const answer = logic.release(labelled, select(logic, "trusted", "never"));
            assert.equal(answer.content, "[withheld: screen content]"); });
    control("asked-marker", 'content: marker, labels: current.labels, needed:', 'content: current.content, labels: current.labels, needed:',
        logic => assert.equal(logic.release(fileText, select(logic)).content, "[withheld: file text]"));
    console.log("test-jarvis-release: ok cases=" + cases + " controls=" + controls);
});
