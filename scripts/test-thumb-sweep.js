#!/usr/bin/env node
"use strict";

// Execute thumbnail sweep decisions from the shipped region.
// Plans retain attempt counts for unseen identities and forget confirmed thumbnails.
// A structured command result completes a sweep even when every requested thumbnail failed.
// The service spends its one discovery sweep at dispatch and never restores it.

const test = require("node:test");
const assert = require("node:assert/strict");
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
test("the marked decision region stays plain JavaScript", () => {
    const region = qmlSource.stripComments(
        require("./lib/qml-region.js").regionOf(source, MARKER, "VGSThemeService.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
});

const entry = (name, thumb) => ({ path: `/w/${name}.jpg`, thumbKey: `k-${name}`, thumb: thumb || "" });
const MAX = 2;

test("thumbSweepPlan dispatches for a missing, forced or discovery sweep, stops at the cap, and forgets confirmed identities", () => {
    for (const [entries, attempts, force, discovery, expected, why] of [
        [[entry("a", "/t/a.jpg")], {}, false, false, { sweep: false },
            "nothing missing and no force must not dispatch: a sweep per read would re-run the whole --all every time the switcher opens"],
        [[entry("a")], {}, false, false, { sweep: true, attempts: { "k-a": 1 } }, "a missing thumbnail dispatches and charges the identity once"],
        [[entry("a", "/t/a.jpg")], {}, true, false, { sweep: true, forced: true }, "a forced sweep dispatches with nothing missing"],
        [[], {}, false, true, { sweep: true, forced: false },
            "the discovery sweep dispatches before any read has listed a wallpaper, and is not a force a result could restore"],
        [[entry("a")], { "k-a": 1 }, false, true, { sweep: true, attempts: { "k-a": MAX }, forced: false },
            "the discovery sweep charges a missing identity like any sweep, so the reads after it still stop at the cap"],
        [[entry("a")], {}, true, true, { forced: true }, "a force pending beside the discovery sweep stays restorable"],
        [[entry("a")], { "k-a": MAX }, false, false, { sweep: false },
            "an identity at the cap stops dispatching: an undecodable file must not re-run its decoder rungs on every read"],
        [[{ path: "/w/a.jpg", thumbKey: "k-a-v2", thumb: "" }], { "k-a": MAX }, false, false, { sweep: true },
            "a replaced source is a new identity and earns fresh attempts, or editing a wallpaper in place could never rebuild its thumbnail"],
        [[entry("a", "/t/a.jpg")], { "k-a": 2, "k-elsewhere": 2 }, false, false, { attempts: { "k-elsewhere": 2 } },
            "an identity CONFIRMED to carry a thumbnail is forgotten, so a deleted thumbnail or a replaced source starts from zero, " +
            "while counts for identities this read cannot see are KEPT: rebuilding the record from the current theme refunded them on every switch"]
    ]) {
        const plan = sweep.thumbSweepPlan(entries, attempts, force, discovery, MAX);
        for (const [key, value] of Object.entries(expected))
            assert.deepEqual(plan[key], value, `${key}: ${why}`);
    }
});

const failedJson = (keys) => JSON.stringify({ failed: keys.map(k => ({ path: `/w/${k}`, key: k })) });

test("thumbSweepResult completes on any structured answer, charges reported identities once, and restores a force only on an unparseable one", () => {
    for (const [output, requested, attempts, forced, expected, why] of [
        [failedJson([]), ["k-a"], { "k-a": 1 }, true, { completed: true, restoreForced: false, reread: true },
            "a parseable result is a completed sweep, which SPENDS the forced request and re-reads to swap the rail onto what it built"],
        [failedJson(["k-x"]), ["k-a"], {}, true, { completed: true, attempts: { "k-x": 1 } },
            "a structured failure is a completed sweep, or a machine with no decoder restores the force and re-runs the whole --all on every " +
            "later read; and it charges the identities it reports, including themes not on screen"],
        [failedJson(["k-a"]), ["k-a"], { "k-a": 1 }, false, { attempts: { "k-a": 1 } },
            "an identity this dispatch already charged is NOT charged again, or one failed sweep spends both attempts and the retry never runs"],
        ["not json at all", ["k-a"], { "k-a": 1 }, true, { completed: false, restoreForced: true, reread: false },
            "an unparseable answer did not complete, so the forced request is RESTORED and it must not re-read, which is what stops a broken command spinning"],
        ["", ["k-a"], {}, false, { completed: false, restoreForced: false }, "empty output did not complete and restores nothing when nothing forced it"]
    ]) {
        const out = sweep.thumbSweepResult(output, requested, attempts, forced);
        for (const [key, value] of Object.entries(expected)) {
            assert.deepEqual(out[key], value, `${key}: ${why}`);
        }
    }
});

// scripts/test-theme-startup.js executes the startup handler that dispatches the discovery sweep.
test("the service spends its discovery sweep at dispatch and never arms it again", () => {
    const service = qmlSource(source, "VGSThemeService.qml");
    service.requires(service.body("_sweepWallpaperThumbs"), "_sweepWallpaperThumbs()", [
        ["root._thumbSweepWanted, root._thumbDiscoveryPending, root._thumbMaxAttempts",
            "the plan hears the discovery request apart from the forced one", 1],
        ["root._thumbDiscoveryPending = false;", "any dispatched --all spends the discovery sweep, so it runs once", 1],
        ["root.thumbSweepResult(output, plan.missing, root._thumbAttempts, plan.forced);",
            "only the forced request is restorable; passing discovery here lets an unparseable answer re-arm it", 1]
    ]);
    service.requires(source, "VGSThemeService.qml", [
        ["_thumbDiscoveryPending = true", "nothing re-arms the discovery sweep; only its declaration starts it pending", 0]
    ]);
});
