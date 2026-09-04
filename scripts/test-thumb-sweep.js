#!/usr/bin/env node
"use strict";

// Execute thumbnail sweep decisions from the shipped region.
// Plans retain attempt counts for unseen identities and forget confirmed thumbnails.
// A structured command result completes a sweep even when every requested thumbnail failed.

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

// Keep extracted decisions independent of QML state.
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
    // Removing a wallpaper can leave nothing missing but still require a forced orphan sweep.
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
    // A replacement file can keep its path while changing cache identity.
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



const failedJson = (keys) => JSON.stringify({ failed: keys.map(k => ({ path: `/w/${k}`, key: k })) });

{
    const out = sweep.thumbSweepResult(failedJson([]), ["k-a"], { "k-a": 1 }, true);
    assert.strictEqual(out.completed, true, "a parseable result is a completed sweep");
    assert.strictEqual(out.restoreForced, false, "which SPENDS the forced request");
    assert.strictEqual(out.reread, true, "and re-reads, to swap the rail onto what it built");
}

{
    // Exit 1 with a structured result is completed failure, not a reason to rerun the entire sweep indefinitely.
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
