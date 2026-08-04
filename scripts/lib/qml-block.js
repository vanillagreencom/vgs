// Extract a brace-delimited body out of a QML file, for tests that want to run
// the SHIPPED code rather than a copy of it.
//
// Naive brace counting is not good enough here. A `{` or `}` inside a comment or
// a string would truncate the extracted body, and a test that quietly stops
// covering its subject is exactly the failure mode these tests exist to prevent
// — it goes green while checking nothing. So the scanner skips line comments,
// block comments, and all three string forms (including `${...}` interpolation,
// which can nest code and further strings), and counts braces only in real code.
//
// KNOWN LIMIT: regex literals are not recognised. Telling `/` as division from
// `/` as a regex delimiter needs a real JS lexer, so a regex literal containing
// an unbalanced brace (`/[{]/`) would confuse the scan. No body extracted by
// these tests contains one. When the scan does go wrong it fails loudly rather
// than silently: an unterminated string or unbalanced brace throws, and every
// caller additionally asserts on content it expects the body to contain.

"use strict";

/**
 * Return the text between the braces of the block introduced by `opener`.
 *
 * @param {string} text      full file contents
 * @param {string} opener    a literal appearing immediately before the block
 * @param {number} fromIndex where to start searching for `opener`
 * @returns {string} the block body, excluding the outer braces
 */
function extractBlock(text, opener, fromIndex = 0) {
    const start = text.indexOf(opener, fromIndex);
    if (start === -1) throw new Error(`could not find ${JSON.stringify(opener)}`);

    const open = text.indexOf("{", start);
    if (open === -1) throw new Error(`no opening brace after ${JSON.stringify(opener)}`);

    // skipBalanced returns the index just past the matching `}`.
    const end = skipBalanced(text, open, opener);
    return text.slice(open + 1, end - 1);
}

/** Advance from an opening `{` at `i` to just past its matching `}`. */
function skipBalanced(text, i, what) {
    let depth = 0;
    let j = i;

    while (j < text.length) {
        const c = text[j];
        const next = text[j + 1];

        if (c === "/" && next === "/") {
            const nl = text.indexOf("\n", j);
            j = nl === -1 ? text.length : nl + 1;
            continue;
        }
        if (c === "/" && next === "*") {
            const close = text.indexOf("*/", j + 2);
            if (close === -1) throw new Error("unterminated block comment");
            j = close + 2;
            continue;
        }
        if (c === '"' || c === "'") {
            j = skipQuoted(text, j, c);
            continue;
        }
        if (c === "`") {
            j = skipTemplate(text, j);
            continue;
        }

        if (c === "{") depth++;
        else if (c === "}") {
            depth--;
            if (depth === 0) return j + 1;
        }
        j++;
    }

    throw new Error(`unbalanced braces after ${JSON.stringify(what ?? "{")}`);
}

/** Advance past a '...' or "..." literal opened at `i`. */
function skipQuoted(text, i, quote) {
    let j = i + 1;
    while (j < text.length) {
        const c = text[j];
        if (c === "\\") {
            j += 2;
            continue;
        }
        if (c === quote) return j + 1;
        if (c === "\n") break; // neither form may span a line unescaped
        j++;
    }
    throw new Error("unterminated string literal");
}

/** Advance past a `...` template literal opened at `i`, interpolation included. */
function skipTemplate(text, i) {
    let j = i + 1;
    while (j < text.length) {
        const c = text[j];
        if (c === "\\") {
            j += 2;
            continue;
        }
        if (c === "`") return j + 1;
        if (c === "$" && text[j + 1] === "{") {
            // The interpolation is ordinary code: hand it to the brace scanner,
            // which will itself skip any nested strings or comments, then carry
            // on inside the template.
            j = skipBalanced(text, j + 1, "${");
            continue;
        }
        j++;
    }
    throw new Error("unterminated template literal");
}

module.exports = { extractBlock };
