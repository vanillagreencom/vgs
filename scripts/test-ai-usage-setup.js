#!/usr/bin/env node

// Test the REPLY DECISION region of AiUsageProviderSetup.qml: what one helper reply means for the
// page's buttons and its single status line. It runs the SHIPPED source, extracted from the QML.
//
// The invariant this file exists to hold: a reply the user did not ask for — the background source
// read, which every action also raises — must not release `busy`. Releasing it there let a read
// landing mid-save unlock Save, Test and Remove under an operation that was still in flight, and
// whichever finished second wrote the status line.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SETUP = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageProviderSetup.qml");

const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

guardChild();

const setupSource = fs.readFileSync(SETUP, "utf8");
const { decodeReply, replyDecision, actionOutcome } = evaluateMarked(
    setupSource, "REPLY DECISION", ["decodeReply", "replyDecision", "actionOutcome"],
    "AiUsageProviderSetup.qml");

const region = regionOf(setupSource, "REPLY DECISION", "AiUsageProviderSetup.qml");

test("the REPLY DECISION region stays plain JavaScript", () => {
    for (const forbidden of ["root.", "Theme.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the REPLY DECISION block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, decided apart from the page state it is then applied to");
    }
});

test("decodeReply answers only for an object, and treats anything else as no answer", () => {
    for (const [text, expected, why] of [
        ['{"ok":true}', { ok: true }, "a reply is a JSON object"],
        ['  {"ok":false,"error":"nope"}\n', { ok: false, error: "nope" },
            "surrounding whitespace is not part of it"],
        ["", null, "a helper that printed nothing answered nothing"],
        ["   \n ", null, "and neither did one that printed only whitespace"],
        ["not json", null, "unparseable output is not a reply"],
        ["42", null, "a bare number parses, and answers nothing: it carries no ok and no error"],
        ['"stored"', null, "and neither does a bare string"],
        ["null", null, "nor a literal null"],
        [undefined, null, "nor a stream that was never read"]
    ]) {
        assert.deepEqual(decodeReply(text), expected, `${JSON.stringify(text)}: ${why}`);
    }
    // An array is an object to typeof, and would reach the caller's payload handler.
    assert.deepEqual(decodeReply("[1,2]"), [1, 2],
        "an array is delivered as-is; the caller reads named fields off it and finds none, which " +
        "is the same outcome as a reply that answered nothing");
});

test("only a reply the user asked for releases the buttons or writes the status line", () => {
    for (const [text, owned, expected, why] of [
        ['{"ok":true}', true, { release: true, deliver: true, failed: false, announce: "" },
            "an owned reply that parsed frees the buttons and is applied, quietly"],
        ['{"ok":true}', false, { release: false, deliver: true, failed: false, announce: "" },
            "THE INVARIANT: the background read is applied but releases nothing — it can land " +
            "in the middle of a save, and freeing Save there unlocks it under itself"],
        ["", true, { release: true, deliver: false, failed: true,
                     announce: "No answer from the vshell helper." },
            "an owned action whose helper said nothing must still free the buttons, or the page " +
            "sits on 'Saving…' with every control dead"],
        ["", false, { release: false, deliver: false, failed: false, announce: "" },
            "while the same silence on the background read reports nothing: it is not a verdict " +
            "on anything the user did"],
        ["not json", false, { release: false, deliver: false, failed: false, announce: "" },
            "and neither is unreadable output from it"]
    ]) {
        const got = replyDecision(text, owned);
        assert.deepEqual(
            { release: got.release, deliver: got.deliver, failed: got.failed, announce: got.announce },
            expected, `${JSON.stringify(text)} owned=${owned}: ${why}`);
    }
    assert.deepEqual(replyDecision('{"ok":true,"dirs":[]}', true).payload, { ok: true, dirs: [] },
        "and the payload delivered is the reply itself, not a copy of part of it");
});

test("an action reports what happened, and a refusal is never announced as a change", () => {
    for (const [payload, expected, why] of [
        [{ ok: true }, { applied: true, failed: false, announce: "Saved." },
            "a helper that applied the change says so in the caller's own words"],
        [{ ok: false, error: "that key is not one VGS stores" },
            { applied: false, failed: true, announce: "that key is not one VGS stores" },
            "a REFUSAL is not a change: announcing it as one told the user a key was gone while " +
            "the helper went on reading it"],
        [{ ok: false, error: "could not save the key", detail: "Read-only file system" },
            { applied: false, failed: true,
              announce: "could not save the key — Read-only file system" },
            "and the detail is appended, because 'could not save' alone names no cause"],
        [{ ok: false }, { applied: false, failed: true, announce: "Could not apply the change." },
            "a failure with no reason still reads as a failure rather than as success"],
        [{}, { applied: false, failed: true, announce: "Could not apply the change." },
            "a reply that never says ok is not a success: absent is not true"],
        [{ ok: "true" }, { applied: false, failed: true, announce: "Could not apply the change." },
            "and neither is the STRING 'true', which is what a shell-built payload emits"],
        [null, { applied: false, failed: true, announce: "Could not apply the change." },
            "nor is nothing at all"]
    ]) {
        assert.deepEqual(actionOutcome(payload, "Saved."), expected,
            `${JSON.stringify(payload)}: ${why}`);
    }
});
