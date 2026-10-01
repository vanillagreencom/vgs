// A bounded server-sent events reader for wire brain adapters. It parses the
// WHATWG event stream format from bytes and owns no transport or timer.
// https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation
"use strict";

const LF = 0x0a;
const CR = 0x0d;
const BOM = "﻿";

function fail(code) { throw new Error("jarvis: sse=" + code); }

/**
 * reader({line, event, total}) bounds, in bytes: one line before its
 * terminator, one event's data buffer, and everything pushed. Past any bound,
 * and on bytes that are not UTF-8, push throws a keyed error and the reader
 * refuses further input. push(bytes) returns the events the bytes complete,
 * each {event, data}. A provider's id and retry fields are ignored: a brain
 * turn is never resumed by reconnection. An event unfinished when the caller
 * stops is discarded, as the format requires; adapters judge completeness by
 * their own terminator.
 */
function reader(limits) {
    for (const name of ["line", "event", "total"])
        if (!limits || !Number.isSafeInteger(limits[name]) || limits[name] < 1) fail("limits");
    // Fatal decoding refuses invalid UTF-8 rather than speaking replacement
    // characters. Each line is complete, so no sequence spans two decodes.
    const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
    let parts = [];
    let pending = 0;
    let total = 0;
    let afterCR = false;
    let first = true;
    let type = "";
    let data = "";
    let dataBytes = 0;
    let hasData = false;
    let failed = false;

    function line(bytes) {
        let text;
        try { text = decoder.decode(bytes); } catch { fail("utf8"); }
        if (first && text.startsWith(BOM)) text = text.slice(1);
        first = false;
        if (text === "") {
            const events = hasData ? [{ event: type === "" ? "message" : type, data: data.slice(0, -1) }] : [];
            type = ""; data = ""; dataBytes = 0; hasData = false;
            return events;
        }
        // A comment line has an empty field name, which no branch reads.
        const colon = text.indexOf(":");
        const field = colon < 0 ? text : text.slice(0, colon);
        let value = colon < 0 ? "" : text.slice(colon + 1);
        if (value.startsWith(" ")) value = value.slice(1);
        if (field === "event") type = value;
        else if (field === "data") {
            dataBytes += Buffer.byteLength(value) + 1;
            if (dataBytes > limits.event) fail("event-limit");
            data += value + "\n";
            hasData = true;
        }
        return [];
    }

    function push(chunk) {
        if (failed) fail("failed");
        try {
            if (!(chunk instanceof Uint8Array)) fail("chunk");
            total += chunk.length;
            if (total > limits.total) fail("total-limit");
            const events = [];
            let start = 0;
            if (afterCR && chunk.length > 0 && chunk[0] === LF) start = 1;
            afterCR = false;
            for (let index = start; index < chunk.length; index++) {
                const byte = chunk[index];
                if (byte !== LF && byte !== CR) continue;
                if (pending + index - start > limits.line) fail("line-limit");
                parts.push(chunk.subarray(start, index));
                events.push(...line(Buffer.concat(parts)));
                parts = [];
                pending = 0;
                if (byte === CR) {
                    if (index + 1 < chunk.length) { if (chunk[index + 1] === LF) index++; }
                    else afterCR = true;
                }
                start = index + 1;
            }
            if (start < chunk.length) {
                pending += chunk.length - start;
                if (pending > limits.line) fail("line-limit");
                parts.push(Buffer.from(chunk.subarray(start)));
            }
            return events;
        } catch (error) {
            failed = true;
            throw error;
        }
    }

    return Object.freeze({ push });
}

module.exports = { reader };
