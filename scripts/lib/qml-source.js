// Read QML source through a shared tokenizer for brace extraction and token assertions.
// Regex literals are not tokenized; an unmatched quote in one can desynchronize the scan.
// Region evaluation belongs to qml-region.js. test-ai-usage-wiring.js runs this library self-test.

"use strict";
const assert = require("node:assert/strict");

// Normalize whitespace so line wrapping does not change token assertions.
const flat = text => String(text).replace(/\s+/g, " ");
// Count only when literal text and code structure occur at the same offset.
// Whitespace may be rewrapped; comments and string interiors cannot count.
function codeOccurrences(literalView, structureView, token) {
    const shape = flat(codeOnly(token));
    const at = new RegExp(
        flat(token).replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/ /g, "\\s+"), "g");
    let seen = 0;
    let hit;
    while ((hit = at.exec(literalView)) !== null) {
        if (flat(structureView.slice(hit.index, hit.index + hit[0].length)) === shape)
            seen += 1;
    }
    return seen;
}

// Classify comments and strings together; a delimiter inside either remains text.
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

// Blank ranges while preserving offsets and newlines.
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

// Blank comments and preserve literals for assertions that inspect literal contents.
function stripComments(text) {
    return blankRanges(text, scanRanges(text).comments, false);
}

// Blank comments and string contents to expose code structure.
function codeOnly(text) {
    const ranges = scanRanges(text);
    return blankRanges(blankRanges(text, ranges.comments, false), ranges.strings, true);
}

module.exports = function qmlSource(source, fileLabel) {
    const label = fileLabel || "the source";

    // Walk braces in the structure view and return the original text at the same offsets.
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

    // Locate signatures in code so a comment cannot redirect extraction to an unrelated block.
    function body(name) {
        return blockFrom(indexOf(`function ${name}(`), `${name}()`);
    }

    // Return code offsets that also index the original source.
    function indexOf(needle, from) {
        return structure.indexOf(needle, from);
    }
    function lastIndexOf(needle, from) {
        return structure.lastIndexOf(needle, from);
    }

    // Find handlers at line starts in the structure view.
    function handlers(name) {
        const out = [];
        const at = new RegExp(`^[ \\t]*${name}:`, "gm");
        let hit;
        while ((hit = at.exec(structure)) !== null) {
            const eol = source.indexOf("\n", hit.index);
            const line = source.slice(hit.index, eol === -1 ? source.length : eol);

            out.push(line.includes("{") ? blockFrom(hit.index, `${name} handler`) : line);
        }
        return out;
    }

    // Nested children and JavaScript labels cannot answer a top-level binding lookup.
    function binding(name) {
        const hits = [];
        let depth = 0;
        let lineStart = 0;
        for (let i = 0; i < structure.length; i += 1) {
            const ch = structure[i];
            if (ch === "{") depth += 1;
            else if (ch === "}") depth -= 1;
            else if (ch === "\n") lineStart = i + 1;
            else if (ch === ":" && depth === 1
                    && structure.slice(lineStart, i).trim().split(/\s+/).at(-1) === name) {
                const eol = source.indexOf("\n", i);
                hits.push({ at: i + 1, value: source.slice(i + 1, eol < 0 ? source.length : eol).trim() });
            }
        }
        assert.equal(hits.length, 1, `${label} must define ${name} exactly once at component top level, found ${hits.length}`);
        const hit = hits[0];
        return { value: hit.value, block: hit.value.startsWith("{") ? blockFrom(hit.at, `${name} binding`) : null };
    }

    // Require each token text and its code structure at the same offset. Separate matches
    // can combine a decoy statement with a literal from an unrelated string.
    // Optional [token, why, count] entries require an exact occurrence count.
    function requires(block, where, pairs) {
        const literalView = stripComments(block);
        const structureView = codeOnly(block);
        for (const [token, why, count] of pairs) {
            const seen = codeOccurrences(literalView, structureView, token);
            if (count === undefined) {
                assert.ok(seen > 0,
                    `${where} must keep \`${token}\` as CODE, with its own literals — ${why}`);
            } else {
                assert.equal(seen, count,
                    `${where} must keep \`${token}\` exactly ${count} time(s) as code, found ` +
                    `${seen} — ${why}`);
            }
        }
    }

    return { blockFrom, body, binding, handlers, requires, indexOf, lastIndexOf, flat, stripComments };
};
module.exports.flat = flat;
module.exports.stripComments = stripComments;
// Test source-reading helpers before a caller relies on their assertions.
module.exports.selfTest = function selfTest() {
    // The fixture tests a double slash as literal text; no URL syntax is required.
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
    // Assert literal contents as well as the surrounding call so stripping part of a string fails.
    assert.ok(stripComments('const a = "/* not a comment */"; keepMe();')
        .includes("/* not a comment */"),
        "a block-comment marker inside a string is text too, and survives intact");
    assert.ok(!stripComments("a(); // gone\nb();").includes("gone"), "a real line comment goes");
    assert.ok(!stripComments("a(); /* gone */ b();").includes("gone"), "a real block comment goes");
    assert.equal(stripComments("a(); // x\nb();").length, "a(); // x\nb();".length,
        "blanked, not deleted: offsets and line structure survive");


    const bindingFixture = module.exports(`{
property int target: 7
Item { property int target: 8 }
property string decoy: "target: 9"
property var decision: { if (false) { target: 10; } return 7; }
}`, "binding fixture");
    assert.equal(bindingFixture.binding("target").value, "7", "nested and string decoys do not answer");
    assert.ok(bindingFixture.binding("decision").block.includes("return 7"), "block bindings return their body");
    assert.throws(() => module.exports("{ property int x: 1\nproperty int x: 2 }", "duplicate fixture").binding("x"),
        /exactly once/, "duplicate top-level bindings fail loudly");

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


    {
        const q = module.exports(
            'function f() {\n    const decoy = "root.current = d";\n}', "self-test");
        assert.throws(() => q.requires(q.body("f"), "f()", [["root.current = d", "pinned"]]),
            "a token found only inside a string literal must FAIL: deleting the real statement " +
            "would otherwise leave the guard green");
        const real = module.exports('function f() {\n    root.current = d;\n}', "self-test");
        real.requires(real.body("f"), "f()", [["root.current = d", "genuinely in code"]]);
        // The literal view must also match so another string cannot satisfy a string-valued assertion.
        const literal = module.exports('function f() { ch.issue = "could not run"; }', "self-test");
        literal.requires(literal.body("f"), "f()", [['ch.issue = "could not run"', "its own text"]]);
        assert.throws(
            () => literal.requires(literal.body("f"), "f()", [['ch.issue = "something else"', "x"]]),
            "a different literal must not satisfy a pin, which the structure view alone would allow");
        // Keep the expected structure and literal in different occurrences to reject independent-view matches.
        const split = module.exports(
            'function f() {\n    ch.issue = "other";\n    const decoy = \'ch.issue = "could not run"\';\n}',
            "self-test");
        assert.throws(
            () => split.requires(split.body("f"), "f()",
                [['ch.issue = "could not run"', "one statement, not two halves"]]),
            "a pin satisfied by a SHAPE from one statement and a LITERAL from another must FAIL: " +
            "the statement it names is absent, which is the whole thing a pin claims");
    }


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


    {
        // A raw signature lookup can select a comment and return the unrelated block after it.
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
