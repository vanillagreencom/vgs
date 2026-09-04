// Extract brace-delimited QML bodies for tests that evaluate the shipped source.
// Comments, quoted strings, and nested template interpolation do not contribute braces.
// Regex literals are not recognized: an unbalanced brace inside a regex can corrupt extraction.
// Unterminated strings or blocks throw; callers must also assert expected body content.

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
        if (c === "\n") break;
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
            // Template interpolation contains code and can contain further strings and comments.
            j = skipBalanced(text, j + 1, "${");
            continue;
        }
        j++;
    }
    throw new Error("unterminated template literal");
}

module.exports = { extractBlock };
