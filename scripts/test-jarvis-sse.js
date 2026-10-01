#!/usr/bin/env node
// Synthetic event streams from the WHATWG event stream format, 2026-09-30.
// https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation
// In-process bytes only: no socket, provider or recording.
"use strict";
const { assert, path, backend, world, control } = require("./fixtures/jarvis-voice/assertions.js");
const Sse = require(path.join(backend, "Sse.js"));

const LIMITS = { line: 64, event: 64, total: 512 };
const bytes = value => typeof value === "string" ? Buffer.from(value) : Buffer.from(value);
function read(logic, chunks, limits = LIMITS) {
    const reader = logic.reader(limits);
    return chunks.flatMap(chunk => reader.push(bytes(chunk)));
}
const message = data => ({ event: "message", data });

// [name, pushed chunks, events]. Each row also runs byte by byte, so every
// terminator and multibyte sequence crosses a push boundary once.
const rows = [
    ["data", ["data: a\n\n"], [message("a")]],
    ["two-events", ["data: a\n\ndata: b\n\n"], [message("a"), message("b")]],
    ["data-lines", ["data: a\ndata: b\n\n"], [message("a\nb")]],
    ["event-type", ["event: delta\ndata: x\n\n"], [{ event: "delta", data: "x" }]],
    ["type-resets", ["event: delta\ndata: x\n\ndata: y\n\n"], [{ event: "delta", data: "x" }, message("y")]],
    ["comment", [": keep-alive\n\n: note\ndata: a\n\n"], [message("a")]],
    ["crlf", ["data: a\r\ndata: b\r\n\r\n"], [message("a\nb")]],
    ["cr", ["data: a\r\rdata: b\r\r"], [message("a"), message("b")]],
    ["crlf-across-pushes", ["data: a\r", "\ndata: b\r", "\n\r", "\n"], [message("a\nb")]],
    ["no-space", ["data:a\n\n"], [message("a")]],
    ["one-space-removed", ["data:  a\n\n"], [message(" a")]],
    ["bare-field", ["data\n\n"], [message("")]],
    ["empty-value", ["data:\n\n"], [message("")]],
    ["no-data", ["event: delta\n\n"], []],
    ["first-bom", ["﻿data: a\n\n"], [message("a")]],
    ["later-bom", ["data: a\n\n﻿data: b\n\n"], [message("a")]],
    ["ignored-fields", ["id: 7\nretry: 10\nother: x\ndata: a\n\n"], [message("a")]],
    ["unfinished-event", ["data: a\n"], []],
    ["unfinished-line", ["data: a"], []],
    ["multibyte", ["data: é😀\n\n"], [message("é😀")]],
    ["at-line-limit", ["data:" + "x".repeat(59) + "\n\n"], [message("x".repeat(59))]],
    ["at-event-limit", ["data:" + "x".repeat(31) + "\ndata:" + "y".repeat(31) + "\n\n"],
        [message("x".repeat(31) + "\n" + "y".repeat(31))]],
    ["at-total-limit", ["data:" + "x".repeat(LIMITS.total - 7) + "\n\n"], [message("x".repeat(LIMITS.total - 7))],
        { line: 1024, event: 1024, total: LIMITS.total }]
];
for (const [name, chunks, expected, limits] of rows) {
    assert.deepEqual(read(Sse, chunks, limits), expected, name);
    const whole = Buffer.concat(chunks.map(bytes));
    assert.deepEqual(read(Sse, [...whole].map(byte => [byte]), limits), expected, name + " byte by byte");
}
assert.ok(Object.isFrozen(Sse.reader(LIMITS)), "the reader exposes no state");

// [name, pushed chunks, keyed cause]. A refused reader stays refused.
const refusals = [
    ["line-in-chunk", ["data:" + "x".repeat(60) + "\n"], "line-limit"],
    ["line-pending", ["data:" + "x".repeat(60)], "line-limit"],
    ["line-pending-grows", ["data:" + "x".repeat(40), "x".repeat(20)], "line-limit"],
    ["line-across-pushes", ["data:" + "x".repeat(40), "x".repeat(20) + "\n"], "line-limit"],
    ["event", ["data:" + "x".repeat(32) + "\ndata:" + "y".repeat(31) + "\n"], "event-limit"],
    ["total", ["data:" + "x".repeat(LIMITS.total - 7) + "\n\n", "\n"], "total-limit",
        { line: 1024, event: 1024, total: LIMITS.total }],
    ["utf8", [Buffer.from([0x64, 0x61, 0x74, 0x61, 0x3a, 0xc3, 0x28, 0x0a])], "utf8"],
    ["chunk", ["data: a\n\n"], "chunk"]
];
function refused(logic, [name, chunks, cause, limits = LIMITS]) {
    const reader = logic.reader(limits);
    assert.throws(() => {
        for (const chunk of chunks) reader.push(name === "chunk" ? chunk : bytes(chunk));
    }, { message: "jarvis: sse=" + cause }, name);
    assert.throws(() => reader.push(bytes("data: a\n\n")), { message: "jarvis: sse=failed" }, name + " stays refused");
}
for (const row of refusals) refused(Sse, row);
for (const limits of [undefined, {}, { line: 1, event: 1 }, { line: 0, event: 1, total: 1 },
    { line: 1.5, event: 1, total: 1 }, { line: "1", event: 1, total: 1 }])
    assert.throws(() => Sse.reader(limits), { message: "jarvis: sse=limits" });

const row = name => rows.find(item => item[0] === name);
function expect(logic, name) {
    const [, chunks, expected, limits] = row(name);
    assert.deepEqual(read(logic, chunks, limits), expected, name);
}
let controls = 0;
world("sse", root => {
    const mutants = [
        ["crlf-pair", "if (afterCR && chunk.length > 0 && chunk[0] === LF) start = 1;", "",
            logic => expect(logic, "crlf-across-pushes")],
        ["crlf-in-chunk", "if (chunk[index + 1] === LF) index++;", "",
            logic => expect(logic, "crlf")],
        ["space", 'if (value.startsWith(" ")) value = value.slice(1);', "",
            logic => expect(logic, "data")],
        ["bom", "if (first && text.startsWith(BOM)) text = text.slice(1);", "",
            logic => expect(logic, "first-bom")],
        ["bom-first-only", "first && text.startsWith(BOM)", "text.startsWith(BOM)",
            logic => expect(logic, "later-bom")],
        ["final-lf", "data: data.slice(0, -1)", "data",
            logic => expect(logic, "data")],
        ["no-data", "const events = hasData ?", "const events = true ?",
            logic => expect(logic, "no-data")],
        ["type-reset", 'type = ""; data = "";', 'data = "";',
            logic => expect(logic, "type-resets")],
        ["utf8", "fatal: true", "fatal: false",
            logic => refused(logic, refusals.find(item => item[0] === "utf8"))],
        ["line-in-chunk", "if (pending + index - start > limits.line) fail(\"line-limit\");", "",
            logic => refused(logic, refusals.find(item => item[0] === "line-in-chunk"))],
        ["line-pending", "if (pending > limits.line) fail(\"line-limit\");", "",
            logic => refused(logic, refusals.find(item => item[0] === "line-pending"))],
        ["event", 'if (dataBytes > limits.event) fail("event-limit");', "",
            logic => refused(logic, refusals.find(item => item[0] === "event"))],
        ["total", 'if (total > limits.total) fail("total-limit");', "",
            logic => refused(logic, refusals.find(item => item[0] === "total"))],
        ["chunk", 'if (!(chunk instanceof Uint8Array)) fail("chunk");', "",
            logic => refused(logic, refusals.find(item => item[0] === "chunk"))],
        ["failed", 'if (failed) fail("failed");', "",
            logic => refused(logic, refusals.find(item => item[0] === "event"))],
        ["limits", "limits[name] < 1", "false",
            logic => assert.throws(() => logic.reader({ line: 0, event: 1, total: 1 }), { message: "jarvis: sse=limits" })],
        ["copy-pending", "parts.push(Buffer.from(chunk.subarray(start)));", "parts.push(chunk.subarray(start));",
            logic => {
                const reader = logic.reader(LIMITS);
                const reused = Buffer.from("data: ab");
                assert.deepEqual(reader.push(reused), []);
                reused.fill(0x7a);
                assert.deepEqual(reader.push(bytes("\n\n")), [message("ab")], "a caller may reuse its buffer");
            }]
    ];
    for (const [name, needle, replacement, check] of mutants) {
        control(root, name, "Sse.js", needle, replacement, check);
        controls++;
    }
});
console.log("test-jarvis-sse: ok rows=" + rows.length + " refusals=" + refusals.length + " controls=" + controls);
