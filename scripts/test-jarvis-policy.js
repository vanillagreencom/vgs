#!/usr/bin/env node
// Complete profile matrix and independent refusal controls in the J09 world.
"use strict";
const { assert, fs, path, tree, world, seed, mutant } = require("./fixtures/jarvis/policy.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Policy.js");
const Policy = require(file);
const Denied = require("../shell/plugins/vgs.jarvis/backend/Denied.js");

world(() => {
    const { home, project, roots } = seed();
    const newFile = path.join(project, "new");
    const existing = path.join(project, "existing");
    const input = { target: { kind: "application", id: "org.example.Editor" }, text: { effective: [] } };
    const site = { target: { kind: "site", id: "https://example.test", password: false } };
    const context = { profile: "standard", locked: false, taint: { kind: "clean" },
        denied: Denied.create(roots), input, grants: [] };
    const call = (id, args) => ({ id, args });
    const effects = {
        read: call("files.read", { path: existing }),
        reversible: call("windows.focus", { window: "0x123" }),
        input: call("input.text", { text: "literal" }),
        persistent: call("files.write", { path: newFile, text: "" }),
        exec: call("shell.line", { line: "echo literal", cwd: project, network: false }),
        external: call("browser", { command: "submit", args: { ref: "@e1" } }),
        destructive: call("files.delete", { path: existing })
    };
    // Independent J47/J51 call contracts. Key facts name an unbound key so
    // target refusals cannot pass by hitting the own-chord guard instead.
    const inputRoutes = [
        [effects.input, "text"],
        [call("input.key", { chord: "SUPER+A" }), "key", {
            request: "SUPER+A", chord: { modifiers: ["SUPER"], keycode: 38 }, effective: []
        }],
        [call("input.click", { x: 0, y: 0, button: "left" }), "pointer"],
        [call("input.scroll", { x: 0, y: 0, direction: "down", steps: 1 }), "pointer"],
        [call("browser", { command: "click", args: { ref: "@e1" } }), "browser"],
        [call("browser", { command: "fill", args: { ref: "@e1", text: "literal" } }), "browser"],
        [effects.external, "browser"]
    ];
    // Expected decisions are independent of the production profile table.
    const profiles = [
        ["cautious", ["allow", "allow", "confirm", "confirm", "confirm", "confirm", "physical"]],
        ["standard", ["allow", "allow", "scope", "allow", "confirm", "confirm", "physical"]],
        ["trusted", ["allow", "allow", "allow", "allow", "allow", "confirm", "physical"]]
    ];
    function expected(effect, rule) {
        if (rule === "allow") return { kind: "allow", effect };
        const result = { kind: "confirm", effect, physical: rule === "physical" };
        if (rule === "scope") result.scope = "application:org.example.Editor";
        return result;
    }
    function checkCell(logic, profile, effect, rule) {
        const current = { ...context, profile, input: effect === "external" ? site : input };
        assert.deepEqual(logic.decide(effects[effect], current), expected(effect, rule), profile + " " + effect);
    }
    for (const [profile, rules] of profiles)
        Object.keys(effects).forEach((effect, index) => checkCell(Policy, profile, effect, rules[index]));

    const refuse = (logic, action, current, reason) => {
        let result;
        assert.doesNotThrow(() => { result = logic.decide(action, current); }, "typed refusals must not throw");
        assert.deepEqual([result.kind, result.reason], ["refuse", reason], reason);
    };
    for (const [profile] of profiles) {
        for (const locked of [true, undefined, null, "false"])
            for (const action of Object.values(effects))
                refuse(Policy, action, { ...context, profile, locked }, "session-locked");
        for (const taintEffect of ["input", "persistent", "exec", "external"]) {
            const current = { ...context, profile, taint: { kind: "tainted" },
                input: taintEffect === "external" ? site : input, grants: ["application:org.example.Editor"] };
            assert.deepEqual(Policy.decide(effects[taintEffect], current), { kind: "confirm", effect: taintEffect, physical: false });
        }
        for (const effect of ["read", "reversible", "destructive"])
            assert.deepEqual(Policy.decide(effects[effect], { ...context, profile, taint: { kind: "tainted" } }),
                expected(effect, effect === "destructive" ? "physical" : "allow"));
        for (const target of ["vgs", "lock", "polkit"])
            for (const [action, , key] of inputRoutes)
                refuse(Policy, action, { ...context, profile, input: { target: { kind: target, id: "protected" }, key } }, "protected-target");
        for (const [action] of inputRoutes.filter(row => row[1] === "browser")) {
            for (const password of [true, undefined])
                refuse(Policy, action, { ...context, profile, input: { target: { ...site.target, password } } }, "password-target");
            refuse(Policy, action, { ...context, profile, input }, "browser-target");
        }
        for (const file of [
            path.join(home, ".ssh", "absent"), path.join(roots.config, "vgs", "shell.json"),
            path.join(roots.state, "vgs", "jarvis", "audit.jsonl")
        ]) {
            for (const action of [
                call("files.read", { path: file }), call("files.write", { path: file, text: "" }),
                call("files.delete", { path: file }), call("apps.open", { path: file }),
                call("shell.line", { line: "pwd", cwd: file, network: false }),
                call("task.start", { goal: "synthetic task", cwd: file }),
                call("files.move", { from: file, to: newFile }),
                call("files.move", { from: existing, to: file })
            ]) refuse(Policy, action, { ...context, profile }, "protected-path");
        }
        for (const argv of [["sudo", "true"], ["su", "-c", "synthetic"], ["/usr/bin/sudoedit", existing]])
            refuse(Policy, call("shell.argv", { argv, cwd: project, network: false }),
                { ...context, profile }, "privilege-elevation");
    }
    for (const source of ["file", "web", "screen", "agent"]) {
        assert.deepEqual(Policy.observe({ kind: "clean" }, source), { kind: "tainted" });
        assert.deepEqual(Policy.observe({ kind: "tainted" }, source), { kind: "tainted" });
    }
    for (const source of ["speech", "desktop", "clipboard", "command"]) {
        assert.deepEqual(Policy.observe({ kind: "clean" }, source), { kind: "clean" });
        assert.deepEqual(Policy.observe({ kind: "tainted" }, source), { kind: "tainted" });
    }
    assert.throws(() => Policy.observe({ kind: "clean" }, "unknown"), { message: "jarvis: taint=invalid" });
    refuse(Policy, effects.read, { ...context, profile: "unknown" }, "policy-profile");
    refuse(Policy, effects.read, { ...context, taint: null }, "turn-taint");
    refuse(Policy, effects.read, { ...context, denied: null }, "path-context");
    refuse(Policy, call("unknown", {}), context, "unknown-tool");
    refuse(Policy, effects.input, { ...context, input: null }, "input-target");
    refuse(Policy, effects.input, { ...context, input: { target: { kind: "unknown", id: "x" } } }, "input-target");
    refuse(Policy, effects.input, { ...context, input: { target: { kind: "application", id: "" } } }, "input-identity");
    refuse(Policy, effects.input, { ...context, input: site }, "desktop-target");
    refuse(Policy, effects.external, context, "browser-target");
    refuse(Policy, effects.external, { ...context, input: { target: { ...site.target, password: true } } }, "password-target");
    refuse(Policy, effects.external, { ...context, input: { target: { kind: "site", id: site.target.id } } }, "password-target");
    refuse(Policy, effects.input, { ...context, grants: null }, "input-grants");
    assert.deepEqual(Policy.decide(effects.input, { ...context, grants: ["application:org.example.Editor"] }), expected("input", "allow"));
    assert.deepEqual(Policy.decide(effects.input, { ...context, grants: ["application:org.example.Other"] }), expected("input", "scope"));
    const browserInput = call("browser", { command: "fill", args: { ref: "@e1", text: "literal" } });
    assert.deepEqual(Policy.decide(browserInput, { ...context, input: site }),
        { kind: "confirm", effect: "input", physical: false, scope: "site:https://example.test" });
    assert.deepEqual(Policy.decide(browserInput, { ...context, input: site, grants: ["site:https://example.test"] }),
        { kind: "allow", effect: "input" });
    const terminal = { target: { kind: "terminal", id: "org.example.Terminal" }, text: { effective: [] } };
    for (const profile of ["cautious", "standard"])
        for (const kind of ["clean", "tainted"])
            refuse(Policy, effects.input, { ...context, profile, input: terminal, taint: { kind } }, "terminal-text");
    for (const kind of ["clean", "tainted"])
        assert.deepEqual(Policy.decide(effects.input, { ...context, profile: "trusted", input: terminal, taint: { kind } }),
            { kind: "confirm", effect: "destructive", physical: true });
    for (const [profile] of profiles)
        for (const kind of ["clean", "tainted"])
            for (const [action, , key] of inputRoutes.filter(row => ["key", "pointer"].includes(row[1])))
                refuse(Policy, action, { ...context, profile, taint: { kind },
                    input: { ...terminal, key }, grants: ["terminal:org.example.Terminal"] }, "terminal-input");
    const pressed = call("input.key", { chord: "ALT+SUPER+Y" });
    const keyContext = { ...context, input: { ...input, key: {
        request: pressed.args.chord, chord: { modifiers: ["ALT", "SUPER"], keycode: 29 },
        effective: [{ modifiers: ["SUPER", "ALT"], keycode: 29 }],
        emitted: { modifiers: ["SUPER", "ALT"], keycode: 9 }, emittedEffective: []
    } } };
    for (const [profile] of profiles)
        refuse(Policy, pressed, { ...keyContext, profile }, "jarvis-chord");
    const codePressed = call("input.key", { chord: "SUPER+ALT+code:29" });
    // The producer resolves both spellings to the same physical key identity.
    refuse(Policy, codePressed, { ...keyContext, input: { ...keyContext.input,
        key: { ...keyContext.input.key, request: codePressed.args.chord } } }, "jarvis-chord");
    refuse(Policy, pressed, context, "key-context");
    refuse(Policy, pressed, { ...keyContext, input: { ...keyContext.input,
        key: { ...keyContext.input.key, request: "SUPER+A" } } }, "key-context");
    for (const chord of [{ modifiers: ["SUPER", "SUPER"], keycode: 29 }, { modifiers: [""], keycode: 29 },
        { modifiers: [], keycode: 0 }, null])
        refuse(Policy, pressed, { ...keyContext, input: { ...keyContext.input,
            key: { ...keyContext.input.key, chord } } }, "key-context");
    const allowedKey = { ...keyContext, profile: "trusted", input: { ...keyContext.input,
        key: { ...keyContext.input.key, effective: [{ modifiers: ["SUPER"], keycode: 29 }] } } };
    assert.deepEqual(Policy.decide(pressed, allowedKey), expected("input", "allow"));

    const overwrite = call("files.write", { path: existing, text: "replace" });
    const moved = call("files.move", { from: existing, to: newFile });
    const moveOverwrite = call("files.move", { from: existing, to: existing });
    const executionWrite = call("files.write", { path: path.join(home, ".bashrc"), text: "" });
    const executionWorkspace = call("shell.argv", { argv: ["pwd"], cwd: path.join(home, ".local/bin"), network: true });
    for (const [profile] of profiles) {
        for (const action of [overwrite, moveOverwrite, executionWrite, executionWorkspace])
            for (const kind of ["clean", "tainted"])
                assert.deepEqual(Policy.decide(action, { ...context, profile, taint: { kind } }), expected("destructive", "physical"));
        assert.deepEqual(Policy.decide(moved, { ...context, profile }),
            expected("persistent", profile === "cautious" ? "confirm" : "allow"));
    }
    const linkedProfile = path.join(project, "profile");
    fs.symlinkSync(path.join(home, ".bashrc"), linkedProfile);
    // A dangling link is refused, not classified as an absent write.
    refuse(Policy, call("files.write", { path: linkedProfile, text: "" }), context, "path-resolution");

    let controls = 0;
    function control(name, needle, replacement, assertion) {
        mutant(file, name, needle, replacement, assertion);
        controls++;
    }
    const source = fs.readFileSync(file, "utf8");
    for (const [profile, rules] of profiles) {
        const line = source.split("\n").find(line => line.trim().startsWith(profile + ": {"));
        Object.keys(effects).forEach((effect, index) => {
            const original = rules[index] === "scope" ? "application" : rules[index];
            const wrong = original === "allow" ? "confirm" : "allow";
            control("profile-" + profile + "-" + effect, line, line.replace(`${effect}: "${original}"`, `${effect}: "${wrong}"`),
                logic => checkCell(logic, profile, effect, rules[index]));
        });
    }
    control("lock", 'if (!context || context.locked !== false)', 'if (false && (!context || context.locked !== false))',
        logic => refuse(logic, effects.reversible, { ...context, locked: true }, "session-locked"));
    control("unknown-profile", 'if (!Object.hasOwn(PROFILES, context.profile))',
        'if (false && !Object.hasOwn(PROFILES, context.profile))',
        logic => refuse(logic, effects.read, { ...context, profile: "unknown", denied: null }, "policy-profile"));
    control("missing-taint", 'if (!context.taint || !["clean", "tainted"].includes(context.taint.kind))',
        'if (false && (!context.taint || !["clean", "tainted"].includes(context.taint.kind)))',
        logic => refuse(logic, call("unknown", {}), { ...context, taint: null }, "turn-taint"));
    control("typed-call", 'if (refined.kind === "refuse") return refined;',
        'if (refined.kind === "refuse") return { kind: "allow", effect: "read" };',
        logic => refuse(logic, call("unknown", {}), context, "unknown-tool"));
    control("path-context", 'return { kind: "refuse", reason: "path-context" };',
        'return { kind: "allow", effect: "read" };',
        logic => refuse(logic, effects.read, { ...context, denied: null }, "path-context"));
    control("denied-answer", 'if (target.kind === "refuse") return target;',
        'if (target.kind === "refuse") return { kind: "allow", effect: "read" };',
        logic => refuse(logic, call("files.read", { path: path.join(home, ".ssh", "absent") }), context, "protected-path"));
    control("execution-write", 'target.execution || role === "remove"', 'false || role === "remove"',
        logic => assert.deepEqual(logic.decide(executionWrite, context), expected("destructive", "physical")));
    control("overwrite", '(role === "write" && target.exists)', '(false && role === "write" && target.exists)',
        logic => assert.deepEqual(logic.decide(overwrite, context), expected("destructive", "physical")));
    control("input-target", 'return { kind: "refuse", reason: "input-target" };',
        'return { kind: "allow", effect: "input" };',
        logic => refuse(logic, effects.input, { ...context, input: null }, "input-target"));
    control("protected-target", 'if (["vgs", "lock", "polkit"].includes(input.target.kind))',
        'if (false && ["vgs", "lock", "polkit"].includes(input.target.kind))',
        logic => refuse(logic, effects.input, { ...context, profile: "trusted",
            input: { target: { kind: "vgs", id: "protected" } } }, "protected-target"));
    control("input-id", 'if (typeof input.target.id !== "string" || input.target.id === "")',
        'if (false && (typeof input.target.id !== "string" || input.target.id === ""))',
        logic => refuse(logic, effects.input, { ...context, input: { target: { kind: "application", id: "" } } }, "input-identity"));
    control("browser-target", 'if (input.target.kind !== "site")',
        'if (false && input.target.kind !== "site")',
        logic => refuse(logic, effects.external, context, "browser-target"));
    control("password", 'if (input.target.password !== false)',
        'if (false && input.target.password !== false)',
        logic => refuse(logic, effects.external, { ...context, input: { target: { ...site.target, password: true } } }, "password-target"));
    control("desktop-target", 'if (input.target.kind === "site")',
        'if (false && input.target.kind === "site")',
        logic => refuse(logic, effects.input, { ...context, input: site }, "desktop-target"));
    control("key-context", 'return { kind: "refuse", reason: "key-context" };',
        'return { kind: "allow", effect: "input" };',
        logic => refuse(logic, pressed, context, "key-context"));
    const unbound = { ...keyContext, input: { ...keyContext.input,
        key: { ...keyContext.input.key, effective: [] } } };
    control("key-request", 'key.request !== call.args.chord', 'false',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, request: "other" } } }, "key-context"));
    control("effective-shapes", '!key.effective.every(chord)', 'false',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, effective: [{ modifiers: [], keycode: 0 }] } } }, "key-context"));
    control("effective-array", '!Array.isArray(key.effective)', 'false',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, effective: {} } } }, "key-context"));
    control("modifier-array", 'Array.isArray(value.modifiers)', 'true',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, chord: { modifiers: "SUPER", keycode: 29 } } } }, "key-context"));
    control("chord-positive", 'value.keycode > 0', 'true',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, chord: { modifiers: [], keycode: 0 } } } }, "key-context"));
    control("chord-integer", 'Number.isSafeInteger(value.keycode)', 'true',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, chord: { modifiers: [], keycode: 0.5 } } } }, "key-context"));
    control("chord-modifier-set", 'new Set(value.modifiers).size === value.modifiers.length', 'true',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, chord: { modifiers: ["SUPER", "SUPER"], keycode: 29 } } } }, "key-context"));
    control("chord-modifier-kind", 'value.modifiers.every(mod => typeof mod === "string" && mod !== "")', 'true',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, chord: { modifiers: [null], keycode: 29 } } } }, "key-context"));
    control("emitted-context", '!chord(key.emitted)', 'false',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, emitted: undefined } } }, "key-context"));
    control("emitted-own-chord", 'if (key.emittedEffective.some(bound => sameChord(key.emitted, bound)))',
        'if (false && key.emittedEffective.some(bound => sameChord(key.emitted, bound)))',
        logic => refuse(logic, pressed, { ...unbound, input: { ...unbound.input,
            key: { ...unbound.input.key, emittedEffective: [{ modifiers: ["SUPER", "ALT"], keycode: 9 }] } } }, "jarvis-chord"));
    control("text-context", 'return { kind: "refuse", reason: "text-context" };',
        'return { kind: "allow", effect: "input" };',
        logic => refuse(logic, effects.input, { ...context, input: { ...input, text: undefined } }, "text-context"));
    control("own-chord", 'if (key.effective.some(bound => sameChord(key.chord, bound)))',
        'if (false && key.effective.some(bound => sameChord(key.chord, bound)))',
        logic => refuse(logic, pressed, keyContext, "jarvis-chord"));
    control("chord-modifiers", 'left.modifiers.slice().sort().join(",") === right.modifiers.slice().sort().join(",")',
        'true', logic => assert.deepEqual(logic.decide(pressed, allowedKey), expected("input", "allow")));
    control("chord-keycode", 'left.keycode === right.keycode', 'true',
        logic => assert.deepEqual(logic.decide(pressed, { ...keyContext, profile: "trusted", input: { ...keyContext.input,
            key: { ...keyContext.input.key, effective: [{ modifiers: ["SUPER", "ALT"], keycode: 30 }] } } }), expected("input", "allow")));
    control("terminal-refusal", 'if (context.profile !== "trusted")',
        'if (false && context.profile !== "trusted")',
        logic => refuse(logic, effects.input, { ...context, input: terminal }, "terminal-text"));
    control("terminal-nontext", 'if (input.target.kind === "terminal" && refined.input !== "text")',
        'if (false && input.target.kind === "terminal" && refined.input !== "text")',
        logic => {
            for (const [action, , key] of inputRoutes.filter(row => ["key", "pointer"].includes(row[1])))
                refuse(logic, action, { ...context, profile: "trusted",
                    input: { ...terminal, key }, grants: ["terminal:org.example.Terminal"] }, "terminal-input");
        });
    control("terminal-physical", 'effect = "destructive";\n        }', 'effect = "input";\n        }',
        logic => assert.deepEqual(logic.decide(effects.input, { ...context, profile: "trusted", input: terminal }), expected("destructive", "physical")));
    control("grant-context", 'return { kind: "refuse", reason: "input-grants" };',
        'return { kind: "allow", effect: "input" };',
        logic => refuse(logic, effects.input, { ...context, grants: null }, "input-grants"));
    control("grant-scope", 'if (!context.grants.includes(scope))',
        'if (false && !context.grants.includes(scope))',
        logic => assert.deepEqual(logic.decide(effects.input, context), expected("input", "scope")));
    control("grant-applied", 'if (!context.grants.includes(scope))', 'if (true)',
        logic => assert.deepEqual(logic.decide(effects.input, { ...context, grants: ["application:org.example.Editor"] }), expected("input", "allow")));
    control("grant-identity", 'scope = input.target.kind + ":" + input.target.id;',
        'scope = input.target.kind + ":" + "org.example.Editor";',
        logic => assert.equal(logic.decide(effects.input, { ...context,
            input: { target: { kind: "application", id: "org.example.Other" }, text: { effective: [] } },
            grants: ["application:org.example.Editor"] }).kind, "confirm"));
    control("taint-upgrade", 'if (context.taint.kind === "tainted" &&',
        'if (false && context.taint.kind === "tainted" &&',
        logic => assert.deepEqual(logic.decide(effects.persistent, { ...context, taint: { kind: "tainted" } }), expected("persistent", "confirm")));
    // External already confirms in every profile. Removing only its taint
    // entry cannot change a decision; the profile matrix pins that guarantee.
    for (const effect of ["persistent", "exec", "input"]) {
        const needle = '["persistent", "exec", "input", "external"].includes(effect)';
        const replacement = needle.replace(`"${effect}"`, '"removed"');
        control("taint-effect-" + effect, needle, replacement,
            logic => assert.deepEqual(logic.decide(effects[effect], { ...context, profile: "trusted",
                taint: { kind: "tainted" } }), expected(effect, "confirm")));
    }
    control("physical-before-taint", 'if (rule === "physical") return { kind: "confirm", effect, physical: true };',
        'if (rule === "physical") return { kind: "confirm", effect, physical: false };',
        logic => assert.deepEqual(logic.decide(effects.destructive, { ...context, taint: { kind: "tainted" } }), expected("destructive", "physical")));
    for (const source of ["file", "screen", "web", "agent"]) {
        const needle = 'const TAINT_SOURCES = ["file", "screen", "web", "agent"];';
        control("taint-source-" + source, needle, needle.replace(`"${source}"`, '"removed"'),
            logic => assert.deepEqual(logic.observe({ kind: "clean" }, source), { kind: "tainted" }));
    }
    control("taint-sticky", 'taint.kind === "tainted" || TAINT_SOURCES.includes(source)', 'TAINT_SOURCES.includes(source)',
        logic => assert.deepEqual(logic.observe({ kind: "tainted" }, "speech"), { kind: "tainted" }));
    control("taint-invalid", 'throw new Error("jarvis: taint=invalid");', 'return { kind: "clean" };',
        logic => assert.throws(() => logic.observe({ kind: "clean" }, "unknown"), { message: "jarvis: taint=invalid" }));
    const toolsFile = path.join(tree, "shell/plugins/vgs.jarvis/backend/Tools.js");
    const toolsSource = fs.readFileSync(toolsFile, "utf8");
    // Remove only routing. The schema and effect remain valid, so the same
    // policy assertions must reject the resulting allowed action, not a parse.
    for (const [action, route, key] of inputRoutes) {
        const line = toolsSource.split("\n").find(line => action.id === "browser"
            ? line.trim().startsWith(action.args.command + ": {") : line.trim().startsWith(`"${action.id}": {`));
        mutant(toolsFile, "input-route-" + action.id + "-" + (action.args.command || ""),
            line, line.replace(`input: "${route}"`, "input: null"), logic => {
                for (const [profile] of profiles) {
                    for (const target of ["vgs", "lock", "polkit"])
                        refuse(logic, action, { ...context, profile,
                            input: { target: { kind: target, id: "protected" }, key } }, "protected-target");
                    if (route === "browser")
                        for (const password of [true, undefined])
                            refuse(logic, action, { ...context, profile, input: { target: { ...site.target, password } } }, "password-target");
                }
            }, "Policy.js");
        controls++;
    }
    for (const [id, args, field, role] of [
        ["files.read", { path: path.join(home, ".ssh", "absent") }, "path", "read"],
        ["apps.open", { path: path.join(home, ".ssh", "absent") }, "path", "read"],
        ["files.list", { path: path.join(home, ".ssh") }, "path", "read"],
        ["files.search", { path: home, query: "synthetic" }, "path", "tree-read"],
        ["files.write", { path: path.join(home, ".ssh", "absent"), text: "" }, "path", "write"],
        ["files.delete", { path: path.join(home, ".ssh") }, "path", "remove"],
        ["files.move", { from: path.join(home, ".ssh"), to: newFile }, "from", "move"],
        ["files.move", { from: existing, to: path.join(home, ".ssh", "absent") }, "to", "write"],
        ["shell.argv", { argv: ["pwd"], cwd: path.join(home, ".ssh"), network: false }, "cwd", "workspace"],
        ["shell.line", { line: "pwd", cwd: path.join(home, ".ssh"), network: false }, "cwd", "workspace"],
        ["task.start", { goal: "synthetic", cwd: path.join(home, ".ssh") }, "cwd", "workspace"]
    ]) {
        const line = toolsSource.split("\n").find(line => line.trim().startsWith(`"${id}": {`));
        const needle = `["${field}", "${role}"]`;
        const replacement = id === "files.move" ? line.replace(needle, "").replace("[,", "[").replace(", ]", "]") : line.replace(needle, "");
        mutant(toolsFile, "path-role-" + id + "-" + field, line, replacement,
            logic => refuse(logic, call(id, args), context, "protected-path"), "Policy.js");
        controls++;
    }
    console.log("test-jarvis-policy: ok profiles=" + profiles.length + " effects=" + Object.keys(effects).length + " controls=" + controls);
});
