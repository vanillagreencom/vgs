// Source-reading helpers for the QML wiring tests: walk a block by braces, pull
// a function body or a signal handler, require load-bearing tokens, strip
// comments. A library, not a check — it has no executable bit and no self-test
// of its own; scripts/test-ai-usage-wiring.js proves each helper against the
// file it reads before leaning on it.
//
// Bound to one source text: `const q = require("./lib/qml-source.js")(text)`.

"use strict";

const assert = require("node:assert/strict");

// Runs of whitespace flattened, so re-wrapping a call across lines is free while
// renaming or reshaping it still fails.
const flat = text => String(text).replace(/\s+/g, " ");

// Comment text is prose about the code, not the code. Only assertions that ban a
// literal outright need this; token matching does not, since the tokens are code.
function stripComments(text) {
    return text
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .split("\n")
        .map(line => {
            const at = line.indexOf("//");
            return at === -1 ? line : line.slice(0, at);
        })
        .join("\n");
}

module.exports = function qmlSource(source, fileLabel) {
    const label = fileLabel || "the source";

    // Brace-depth walk from an offset, so nothing depends on how deeply a block
    // happens to be indented — re-indenting the file must not change what the
    // assertions read.
    function blockFrom(at, what) {
        assert.notEqual(at, -1, `${label} must define ${what}`);
        const open = source.indexOf("{", at);
        assert.notEqual(open, -1, `${what} has no body`);
        let depth = 0;
        for (let i = open; i < source.length; i++) {
            if (source[i] === "{") depth += 1;
            else if (source[i] === "}") {
                depth -= 1;
                if (depth === 0)
                    return source.slice(open, i + 1);
            }
        }
        return assert.fail(`${what} has no closing brace`);
    }

    function body(name) {
        return blockFrom(source.indexOf(`function ${name}(`), `${name}()`);
    }

    // Handlers are found at the start of a line, so a comment MENTIONING one is
    // not mistaken for one — these files are heavily commented precisely because
    // the orderings they encode are subtle.
    function handlers(name) {
        const out = [];
        const at = new RegExp(`^[ \\t]*${name}:`, "gm");
        let hit;
        while ((hit = at.exec(source)) !== null) {
            const eol = source.indexOf("\n", hit.index);
            const line = source.slice(hit.index, eol === -1 ? source.length : eol);
            // A handler is either a block or a single expression on its own line.
            out.push(line.includes("{") ? blockFrom(hit.index, `${name} handler`) : line);
        }
        return out;
    }

    // Every token has to be present, each named on its own so a failure says
    // which line went missing.
    function requires(block, where, pairs) {
        const haystack = flat(block);
        for (const [token, why] of pairs)
            assert.ok(haystack.includes(flat(token)), `${where} must keep \`${token}\` — ${why}`);
    }

    return { blockFrom, body, handlers, requires, flat, stripComments };
};

module.exports.flat = flat;
module.exports.stripComments = stripComments;
