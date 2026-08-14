// Source-reading helpers for the QML tests: walk a block by braces, pull a
// function body or a handler, require load-bearing tokens, strip comments,
// evaluate a marked decision region. A library, not a check — no executable bit,
// so its self-test is exported and test-ai-usage-wiring.js runs it first.
//
// Bound to one source text: `const q = require("./lib/qml-source.js")(text)`.
//
// Everything here reads the source through ONE tokenizer, because both helpers
// were fail-open without it: a `//` or a brace inside a string made stripComments
// drop the rest of the line — and the wiring test asserts a literal is ABSENT
// from what it returns — while blockFrom counted braces in prose and in strings
// as syntax and could hand back a block that is not the one asked for.
//
// KNOWN LIMIT: regex literals are not tokenized — a `/`-delimited regex holding
// an unpaired quote would desync the scan; none of the QML this reads has one.

"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");

// Runs of whitespace flattened, so re-wrapping a call across lines is free while
// renaming or reshaping it still fails.
const flat = text => String(text).replace(/\s+/g, " ");

// One walk over the source, answering where the comments are and where the
// string literals are. A comment marker inside a string is text, and a quote
// inside a comment is text: whichever opens first owns the run.
function scanRanges(text) {
    const comments = [];
    const strings = [];
    let i = 0;
    while (i < text.length) {
        const ch = text[i];
        const next = text[i + 1];
        if (ch === "/" && next === "/") {
            const start = i;
            while (i < text.length && text[i] !== "\n")
                i += 1;
            comments.push([start, i]);
            continue;
        }
        if (ch === "/" && next === "*") {
            const start = i;
            i += 2;
            while (i < text.length && !(text[i] === "*" && text[i + 1] === "/"))
                i += 1;
            i = Math.min(i + 2, text.length);
            comments.push([start, i]);
            continue;
        }
        if (ch === '"' || ch === "'" || ch === "`") {
            const start = i;
            i += 1;
            while (i < text.length) {
                if (text[i] === "\\") {
                    i += 2;
                    continue;
                }
                if (text[i] === ch) {
                    i += 1;
                    break;
                }
                // An unterminated single-line string ends at the newline rather
                // than swallowing the rest of the file.
                if (ch !== "`" && text[i] === "\n")
                    break;
                i += 1;
            }
            strings.push([start, i]);
            continue;
        }
        i += 1;
    }
    return { comments, strings };
}

// Blank the given ranges to spaces, keeping every offset and newline, so an
// index into the result is an index into the original.
function blankRanges(text, ranges, keepDelimiters) {
    const out = text.split("");
    for (const [start, end] of ranges) {
        const from = keepDelimiters ? start + 1 : start;
        const to = keepDelimiters ? Math.max(from, end - 1) : end;
        for (let i = from; i < to; i++) {
            if (out[i] !== "\n")
                out[i] = " ";
        }
    }
    return out.join("");
}

// Comment text is prose about the code, not the code. EVERY read of the source
// goes through this or through codeOnly(): a required token found in a comment
// satisfied requires() while the production statement it pins was deleted, which
// is a guard manufacturing confidence. String literals survive — they ARE code,
// and banning one is the usual reason to call this.
function stripComments(text) {
    return blankRanges(text, scanRanges(text).comments, false);
}

// The source with comments and string CONTENTS blanked: what is left is
// structure, which is the only thing a brace walk may count.
function codeOnly(text) {
    const ranges = scanRanges(text);
    return blankRanges(blankRanges(text, ranges.comments, false), ranges.strings, true);
}

// Evaluate the decision region a QML file marks off, in a context holding
// NOTHING but the JavaScript intrinsics. `new Function` ran that text in this
// process with full ambient authority — process, require, fetch — so a QML-only
// edit executed arbitrary code on the CI runner, and ci.yml triggers on plain
// `pull_request` with no fork guard, which makes a stranger's fork PR the reach.
// The region is plain JavaScript needing only Math, JSON, String and Number, so
// everything else is ABSENT rather than unused. A timeout bounds a planted loop.
function regionOf(source, marker, label) {
    const marked = source.match(
        new RegExp(`// BEGIN ${marker}\\n([\\s\\S]*?)// END ${marker}`)
    );
    assert.ok(marked, `${label} must carry the ${marker} markers`);
    return marked[1];
}

function evaluateMarked(source, marker, names, label) {
    const region = regionOf(source, marker, label);
    // console is Node's, not an intrinsic: shadowed so the region cannot reach it.
    const context = vm.createContext({ console: undefined });
    const factory = `(function () {\n${region}\nreturn { ${names.join(", ")} };\n})()`;
    const exported = vm.runInContext(factory, context,
        { filename: `${label}:${marker}`, timeout: 5000 });

    // Values built inside the sandbox carry ITS intrinsics, so a plain object
    // from there is not deepStrictEqual to one written here. Each function hands
    // its result back as host data; the realm is the sandbox's business.
    const out = {};
    for (const name of names) {
        const value = exported[name];
        out[name] = typeof value === "function"
            ? (...args) => hostValue(value(...args))
            : hostValue(value);
    }
    return out;
}

function hostValue(value) {
    if (value === null || typeof value !== "object")
        return value;
    if (Array.isArray(value)) {
        // Built here: the sandbox's Array.prototype.map returns ITS array.
        const list = [];
        for (let i = 0; i < value.length; i++)
            list.push(hostValue(value[i]));
        return list;
    }
    const out = {};
    for (const key of Object.keys(value))
        out[key] = hostValue(value[key]);
    return out;
}

module.exports = function qmlSource(source, fileLabel) {
    const label = fileLabel || "the source";

    // Brace-depth walk from an offset, so nothing depends on how deeply a block
    // happens to be indented. Braces are counted on the structure-only copy — a
    // brace in prose or in a string is not syntax — while the slice comes from
    // the original, so the assertions read the real text, comments and all.
    const structure = codeOnly(source);

    function blockFrom(at, what) {
        assert.notEqual(at, -1, `${label} must define ${what}`);
        const open = structure.indexOf("{", at);
        assert.notEqual(open, -1, `${what} has no body`);
        let depth = 0;
        for (let i = open; i < structure.length; i++) {
            if (structure[i] === "{") depth += 1;
            else if (structure[i] === "}") {
                depth -= 1;
                if (depth === 0)
                    return source.slice(open, i + 1);
            }
        }
        return assert.fail(`${what} has no closing brace`);
    }

    // Located on the structure-only copy, like every other lookup here: a comment
    // merely MENTIONING a signature matched first on the raw source, and the walk
    // then returned the next structural block — silently inspecting a different
    // function while reporting green.
    function body(name) {
        return blockFrom(indexOf(`function ${name}(`), `${name}()`);
    }

    // Offsets are preserved by codeOnly(), so an index into the structure-only
    // copy is an index into the original. Callers that need to find their own
    // landmark use these rather than searching the raw source.
    function indexOf(needle) {
        return structure.indexOf(needle);
    }
    function lastIndexOf(needle, from) {
        return structure.lastIndexOf(needle, from);
    }

    // Found at the start of a line in the structure-only copy, so a comment
    // MENTIONING a handler is not mistaken for one.
    function handlers(name) {
        const out = [];
        const at = new RegExp(`^[ \\t]*${name}:`, "gm");
        let hit;
        while ((hit = at.exec(structure)) !== null) {
            const eol = source.indexOf("\n", hit.index);
            const line = source.slice(hit.index, eol === -1 ? source.length : eol);
            // A handler is either a block or a single expression on its own line.
            out.push(line.includes("{") ? blockFrom(hit.index, `${name} handler`) : line);
        }
        return out;
    }

    // Every token has to be present, each named on its own so a failure says
    // which line went missing. Searched with COMMENTS BLANKED: a token that
    // survives only in a comment is prose about code that may well be gone, so
    // matching it would pass while the statement this pins was deleted.
    //
    // A pair may carry an exact occurrence count: [token, why, count]. Presence
    // alone could not express "twice" — listing a token in two pairs was
    // satisfied by ONE occurrence, so a second call site meant to be pinned was
    // not — and it cannot express "once and no more" either, which is how an
    // immediate deferral would creep back in beside a delayed retry.
    function requires(block, where, pairs) {
        const haystack = flat(stripComments(block));
        for (const [token, why, count] of pairs) {
            const needle = flat(token);
            if (count === undefined) {
                assert.ok(haystack.includes(needle), `${where} must keep \`${token}\` — ${why}`);
                continue;
            }
            const seen = haystack.split(needle).length - 1;
            assert.equal(seen, count,
                `${where} must keep \`${token}\` exactly ${count} time(s), found ${seen} — ${why}`);
        }
    }

    return { blockFrom, body, handlers, requires, indexOf, lastIndexOf, flat, stripComments };
};

module.exports.evaluateMarked = evaluateMarked;
module.exports.regionOf = regionOf;
module.exports.flat = flat;
module.exports.stripComments = stripComments;

// The self-test a library with no executable bit cannot run for itself. Every
// case below FAILED before the tokenizer went in: the guards could not detect
// the thing they claim to.
module.exports.selfTest = function selfTest() {
    // --- stripComments keeps strings, drops comments ---
    // The property is that a DOUBLE SLASH inside a string literal is text, so the
    // fixture is a plain string rather than a URL — a URL shape here matched a
    // CodeQL substring-sanitization rule that has nothing to do with what this
    // proves.
    for (const [quoted, what] of [
        ['"ratio 3//4 kept"', "double quotes"],
        ["'ratio 3//4 kept'", "single quotes"],
        ["`ratio 3//4 kept`", "backticks"]
    ]) {
        const stripped = stripComments(`const a = ${quoted}; keepMe();`);
        assert.ok(stripped.includes("keepMe()"),
            `a double slash inside ${what} is text, not a comment — dropping the rest of the ` +
            "line would let a banned literal be stripped away before the assertion sees it");
        assert.ok(stripped.includes("3//4 kept"),
            `the string's own content survives intact (${what}), which is what an assertion ` +
            "banning a literal actually reads");
    }
    // The string's CONTENT is what proves this one: the old block-comment regex
    // left `keepMe()` alone but ate the marker out of the literal, so an
    // assertion banning that literal would have passed against nothing.
    assert.ok(stripComments('const a = "/* not a comment */"; keepMe();')
        .includes("/* not a comment */"),
        "a block-comment marker inside a string is text too, and survives intact");
    assert.ok(!stripComments("a(); // gone\nb();").includes("gone"), "a real line comment goes");
    assert.ok(!stripComments("a(); /* gone */ b();").includes("gone"), "a real block comment goes");
    assert.equal(stripComments("a(); // x\nb();").length, "a(); // x\nb();".length,
        "blanked, not deleted: offsets and line structure survive");

    // --- blockFrom counts only structural braces ---
    const cases = [
        ['function f() { // }\n    keepMe();\n}', "a brace in a line comment"],
        ['function f() { /* } */\n    keepMe();\n}', "a brace in a block comment"],
        ['function f() { const s = "}"; keepMe(); }', "a brace in a double-quoted string"],
        ["function f() { const s = '}'; keepMe(); }", "a brace in a single-quoted string"],
        ["function f() { const s = `}`; keepMe(); }", "a brace in a template literal"],
        ['function f() { const s = "{"; keepMe(); }', "an opening brace in a string"]
    ];
    for (const [text, what] of cases) {
        const walked = module.exports(text, "self-test").body("f");
        assert.ok(walked.includes("keepMe()"),
            `${what} must not end the block early — the assertions would then inspect code ` +
            "outside the function they name, and still report green");
        assert.ok(walked.endsWith("}"), `${what} still yields a whole block`);
    }
    assert.ok(module.exports('function f() { g("//"); }\nfunction h() { keepMe(); }', "self-test")
        .body("f").includes('g("//")'),
        "a comment marker inside a string does not swallow the rest of the file either");

    // --- a token that lives only in a comment pins nothing ---
    {
        const q = module.exports(
            'function f() {\n    // ch.stallTimer.stop() used to be here\n    keepMe();\n}',
            "self-test");
        assert.throws(() => q.requires(q.body("f"), "f()", [["ch.stallTimer.stop()", "pinned"]]),
            "a required token found ONLY in a comment must FAIL: otherwise deleting the statement " +
            "it pins leaves the check green, which is a guard manufacturing confidence");
        q.requires(q.body("f"), "f()", [["keepMe()", "still there"]]);
        const withString = module.exports('function f() { g("ch.stallTimer.stop()"); }', "self-test");
        withString.requires(withString.body("f"), "f()",
            [['g("ch.stallTimer.stop()")', "a string literal IS code and still counts"]]);
    }

    // --- an exact count means exactly that ---
    {
        const q = module.exports("function f() { one(); two(); two(); }", "self-test");
        const block = q.body("f");
        q.requires(block, "f()", [["two();", "twice", 2], ["one();", "once", 1]]);
        assert.throws(() => q.requires(block, "f()", [["one();", "twice", 2]]),
            "one occurrence must NOT satisfy a requirement of two — listing a token twice as two " +
            "presence pairs did exactly that, leaving the second call site unpinned");
        assert.throws(() => q.requires(block, "f()", [["two();", "once and no more", 1]]),
            "and a second occurrence must fail a requirement of one, which is how an immediate " +
            "deferral would creep back in beside a delayed retry");
        try {
            q.requires(block, "f()", [["one();", "twice", 2]]);
        } catch (e) {
            assert.ok(e.message.includes("one();") && e.message.includes("twice"),
                "the failure still names the token and the requirement");
        }
    }

    // --- a comment mentioning a signature must not become the block ---
    {
        const decoy = [
            "// see function target( for details",
            "function decoy() { wrongOne(); }",
            "function target() { rightOne(); }"
        ].join("\n");
        const walked = module.exports(decoy, "self-test").body("target");
        assert.ok(walked.includes("rightOne()"),
            "body() must locate the real function, not the block after a comment that mentions it");
        assert.ok(!walked.includes("wrongOne()"), "and never the decoy's body");
    }

    // --- the extracted region gets no ambient authority ---
    {
        const region = names => [
            "// BEGIN SELF TEST", names, "// END SELF TEST"
        ].join("\n");
        const ok = evaluateMarked(
            region("function two() { return Math.max(1, JSON.parse('2')); }\n" +
                   "function shaped() { return { pct: 2, slots: [{ ok: true }] }; }"),
            "SELF TEST", ["two", "shaped"], "self-test");
        assert.equal(ok.two(), 2, "the intrinsics the decision code uses are there");
        assert.deepEqual(ok.shaped(), { pct: 2, slots: [{ ok: true }] },
            "and a value built in the sandbox comes back as host data, or every deepEqual in " +
            "the suites would fail on the realm rather than on the value");

        for (const planted of [
            "process.exit(0);",
            "require('node:fs');",
            "fetch('http://example.invalid');",
            "globalThis.process.env.HOME;"
        ]) {
            assert.throws(
                () => evaluateMarked(region(`${planted}\nfunction f() {}`), "SELF TEST", ["f"],
                    "self-test"),
                /is not defined|Cannot read properties of undefined/,
                `\`${planted}\` planted in the marked region must be REJECTED, not executed — ` +
                "that region comes from a repo file, and a fork PR runs this suite on the runner"
            );
        }
        assert.throws(() => evaluateMarked(region("while (true) {}\nfunction f() {}"),
            "SELF TEST", ["f"], "self-test"), /timed out/,
            "and a planted infinite loop must time out rather than hang CI");
    }

    // --- the lookup helpers read code, not prose ---
    {
        // A raw search finds the mention, and the walk from there returns the
        // NEXT block — the decoy — while still reporting green.
        const text = [
            "// detailsText: mentioned in prose",
            "decoyBlock: { wrongOne(); }",
            "detailsText: { real(); }"
        ].join("\n");
        const q = module.exports(text, "self-test");
        const at = q.indexOf("detailsText:");
        const walked = q.blockFrom(at, "detailsText");
        assert.ok(walked.includes("real()"), "indexOf skips a landmark that exists only in a comment");
        assert.ok(!walked.includes("wrongOne()"), "so the walk cannot land in the block beside it");
        assert.equal(q.lastIndexOf("detailsText:", q.indexOf("real()")), at,
            "and so does the backward search callers use to reach an enclosing block");
    }
};
