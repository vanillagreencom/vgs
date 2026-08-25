#!/usr/bin/env node
"use strict";

// The wallpaper-thumbnail sweep's state machine, EXECUTED.
//
// Every input is an argument, so this runs the same program the shell runs.
// The logic earned this suite the hard way: nearly every review finding on
// VGS-216 lived in these two functions — a lifetime latch that never re-armed,
// a record keyed by path while the cache keys by identity, counts refunded on a
// theme switch, one failed sweep spending both attempts, and a structured
// failure read as a broken command, which re-ran the whole `--all` forever.
//
//   thumbSweepPlan   decides whether a read dispatches a sweep, and what it
//                    charges. Identities confirmed to carry a thumbnail are
//                    forgotten; counts for themes this read cannot see are kept.
//   thumbSweepResult decides what a finished command meant. A parseable answer
//                    is a COMPLETED sweep whatever it exited with.
//
// MUST-FAIL CONTROLS, each seen red one at a time: the plan sweeping with
// nothing missing and no force; the plan refusing a forced sweep; counts
// refunded for an unseen theme; a confirmed thumbnail left in the record; the
// result treating a structured failure as incomplete (the unbounded re-run);
// the result restoring the request after a completed sweep; and a reported
// identity charged twice in one dispatch.

const assert = require("assert");
const path = require("path");
const fs = require("fs");

const REPO = path.resolve(__dirname, "..");
const qmlSource = require("./lib/qml-source.js");
const { evaluateMarked } = require("./lib/qml-region.js");
const SERVICE = path.join(REPO, "quickshell", "vshell", "Services", "VGSThemeService.qml");
const MARKER = "THUMBNAIL SWEEP DECISION";
const source = fs.readFileSync(SERVICE, "utf8");

const sweep = evaluateMarked(source, MARKER, ["thumbSweepPlan", "thumbSweepResult"],
    "VGSThemeService.qml");

// The extracted block must be free of QML, or this harness tests a different
// program than the shell runs.
{
    const region = qmlSource.stripComments(
        require("./lib/qml-region.js").regionOf(source, MARKER, "VGSThemeService.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
}

const entry = (name, thumb) => ({ path: `/w/${name}.jpg`, thumbKey: `k-${name}`, thumb: thumb || "" });
const MAX = 2;

// --- thumbSweepPlan --------------------------------------------------------

{
    const plan = sweep.thumbSweepPlan([entry("a", "/t/a.jpg")], {}, false, MAX);
    assert.strictEqual(plan.sweep, false,
        "nothing missing and no force must not dispatch: a sweep per read would " +
        "re-run the whole --all every time the switcher opens");
}

{
    const plan = sweep.thumbSweepPlan([entry("a")], {}, false, MAX);
    assert.strictEqual(plan.sweep, true, "a missing thumbnail dispatches");
    assert.strictEqual(plan.attempts["k-a"], 1, "and charges the identity once");
}

{
    // A removal leaves nothing missing, which is exactly when the orphan needs
    // sweeping — the force is the only thing that can say so.
    const plan = sweep.thumbSweepPlan([entry("a", "/t/a.jpg")], {}, true, MAX);
    assert.strictEqual(plan.sweep, true, "a forced sweep dispatches with nothing missing");
}

{
    const plan = sweep.thumbSweepPlan([entry("a")], { "k-a": MAX }, false, MAX);
    assert.strictEqual(plan.sweep, false,
        "an identity at the cap stops dispatching: an undecodable file must not " +
        "re-run its decoder rungs on every read");
}

{
    // Keyed on IDENTITY: the same path with a new key is a replaced file.
    const replaced = { path: "/w/a.jpg", thumbKey: "k-a-v2", thumb: "" };
    const plan = sweep.thumbSweepPlan([replaced], { "k-a": MAX }, false, MAX);
    assert.strictEqual(plan.sweep, true,
        "a replaced source is a new identity and earns fresh attempts, or editing " +
        "a wallpaper in place could never rebuild its thumbnail");
}

{
    const plan = sweep.thumbSweepPlan([entry("a", "/t/a.jpg")], { "k-a": 2, "k-elsewhere": 2 }, false, MAX);
    assert.strictEqual(plan.attempts["k-a"], undefined,
        "an identity CONFIRMED to carry a thumbnail is forgotten, so a deleted " +
        "thumbnail or a replaced source starts from zero");
    assert.strictEqual(plan.attempts["k-elsewhere"], 2,
        "counts for identities this read cannot see — every other theme — are KEPT: " +
        "rebuilding the record from the current theme refunded them on every switch");
}

// --- thumbSweepResult ------------------------------------------------------

const failedJson = (keys) => JSON.stringify({ failed: keys.map(k => ({ path: `/w/${k}`, key: k })) });

{
    const out = sweep.thumbSweepResult(failedJson([]), ["k-a"], { "k-a": 1 }, true);
    assert.strictEqual(out.completed, true, "a parseable result is a completed sweep");
    assert.strictEqual(out.restoreForced, false, "which SPENDS the forced request");
    assert.strictEqual(out.reread, true, "and re-reads, to swap the rail onto what it built");
}

{
    // The unbounded re-run: exit 1 with a structured answer is a COMPLETED
    // sweep where everything failed, not a command that could not run.
    const out = sweep.thumbSweepResult(failedJson(["k-x"]), ["k-a"], {}, true);
    assert.strictEqual(out.completed, true,
        "a structured failure is a completed sweep, or a machine with no decoder " +
        "restores the force and re-runs the whole --all on every later read");
    assert.strictEqual(out.attempts["k-x"], 1,
        "and charges the identities it reports, including themes not on screen");
}

{
    const out = sweep.thumbSweepResult(failedJson(["k-a"]), ["k-a"], { "k-a": 1 }, false);
    assert.strictEqual(out.attempts["k-a"], 1,
        "an identity this dispatch already charged is NOT charged again, or one " +
        "failed sweep spends both attempts and the retry never runs");
}

{
    const out = sweep.thumbSweepResult("not json at all", ["k-a"], { "k-a": 1 }, true);
    assert.strictEqual(out.completed, false, "an unparseable answer did not complete");
    assert.strictEqual(out.restoreForced, true,
        "so the forced request is RESTORED — a removal must not lose its only sweep");
    assert.strictEqual(out.reread, false,
        "and it must not re-read, which is what stops a broken command spinning");
}

{
    const out = sweep.thumbSweepResult("", ["k-a"], {}, false);
    assert.strictEqual(out.completed, false, "empty output did not complete");
    assert.strictEqual(out.restoreForced, false, "and restores nothing when nothing forced it");
}

console.log("thumb sweep: all checks passed");
