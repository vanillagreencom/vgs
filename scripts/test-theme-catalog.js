#!/usr/bin/env node
// The catalog marker and install state, bin/lib/theme-catalog.js. Every
// expected value below was written by hand, never read from the library.
//
// The controls at the end edit a copy of the library, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const libFile = path.join(repo, "bin", "lib", "theme-catalog.js");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));

const DIGEST = "0123456789abcdef".repeat(4);
const OTHER = "fedcba9876543210".repeat(4);
const PIN = { repo: "https://github.com/vanillagreencom/vgs-themes", release: "themes-v1", archive: "vgs-theme-moor-r1.tar.gz", size: 42, sha256: DIGEST };
const NEWER = Object.assign({}, PIN, { archive: "vgs-theme-moor-r2.tar.gz", sha256: OTHER });
const marker = (fields) => JSON.stringify(Object.assign({ source: "catalog", digest: DIGEST, imagery: null }, fields));

// Markers the judge accepts: the text and the marker it answers.
const ACCEPTED = [
    [marker({}), { digest: DIGEST, imagery: null }],
    [marker({ imagery: PIN }), { digest: DIGEST, imagery: PIN }],
    [JSON.stringify({ imagery: null, digest: DIGEST, source: "catalog" }), { digest: DIGEST, imagery: null }]
];

// Markers the judge refuses: the text, the refusal's token and its detail.
const REFUSED = [
    ["{", "", /^json=/],
    ["[]", "", /^got=\[\]$/],
    ["null", "", /^got=null$/],
    [marker({ extra: 1 }), "", /^key=extra$/],
    [JSON.stringify({ source: "catalog", digest: DIGEST }), "", /^key=imagery$/],
    [marker({ source: "git" }), "source", /^got="git"$/],
    [marker({ digest: DIGEST.toUpperCase() }), "digest", /^got=/],
    [marker({ digest: DIGEST.slice(1) }), "digest", /^got=/],
    [marker({ digest: 7 }), "digest", /^got=7$/],
    [marker({ imagery: "themes-v1" }), "imagery", /^got="themes-v1"$/],
    [marker({ imagery: Object.assign({}, PIN, { sha256: "x" }) }), "imagery.sha256", /^got="x"$/]
];

// installState: the index entry's imagery, the marker or null, the catalog
// package's digest, and the four keys it answers.
const STATES = [
    [PIN, null, null, { installed: false, imageryInstalled: false, imageryUpdate: false, definitionUpdate: false }],
    [PIN, { digest: DIGEST, imagery: null }, DIGEST, { installed: true, imageryInstalled: false, imageryUpdate: false, definitionUpdate: false }],
    [PIN, { digest: DIGEST, imagery: null }, OTHER, { installed: true, imageryInstalled: false, imageryUpdate: false, definitionUpdate: true }],
    [PIN, { digest: DIGEST, imagery: PIN }, DIGEST, { installed: true, imageryInstalled: true, imageryUpdate: false, definitionUpdate: false }],
    [NEWER, { digest: DIGEST, imagery: PIN }, DIGEST, { installed: true, imageryInstalled: true, imageryUpdate: true, definitionUpdate: false }],
    [null, { digest: DIGEST, imagery: PIN }, DIGEST, { installed: true, imageryInstalled: true, imageryUpdate: false, definitionUpdate: false }]
];

// ThemeLogic runs in a context of its own, so the objects it answers are
// compared as plain data.
const plain = value => JSON.parse(JSON.stringify(value));

function verify(lib) {
    assert.equal(lib.MARKER_FILE, ".vgs-catalog.json");
    assert.deepEqual(JSON.parse(lib.markerText(DIGEST, PIN)), { source: "catalog", digest: DIGEST, imagery: PIN });
    assert.ok(lib.markerText(DIGEST, null).endsWith("}\n"));
    for (const [text, want] of ACCEPTED) {
        const verdict = lib.acceptMarker(logic, text);
        assert.equal(verdict.ok, true, text);
        assert.deepEqual(plain(verdict.marker), want, text);
    }
    assert.deepEqual(plain(lib.acceptMarker(logic, lib.markerText(DIGEST, PIN)).marker), { digest: DIGEST, imagery: PIN });
    for (const [text, token, detail] of REFUSED) {
        const verdict = lib.acceptMarker(logic, text);
        assert.equal(verdict.ok, false, text);
        assert.equal(verdict.reason, "marker", text);
        assert.equal(verdict.token, token, text);
        assert.match(verdict.detail, detail, text);
    }
    for (const [imagery, markerValue, digest, want] of STATES)
        assert.deepEqual(lib.installState({ name: "moor", imagery }, markerValue, digest), want, JSON.stringify([imagery, markerValue, digest]));
}

verify(require(libFile));

const CONTROLS = [
    ['return logic.refusal("marker", "", "json=" + JSON.stringify(e.message));', 'return { ok: true, marker: {} };'],
    ['if (!logic.isPlainObject(doc)) return', 'if (false) return'],
    ['if (!MARKER_KEYS.includes(key)) return', 'if (false) return'],
    ['if (!Object.hasOwn(doc, key)) return', 'if (false) return'],
    ['if (doc.source !== MARKER_SOURCE) return', 'if (false) return'],
    ['typeof doc.digest !== "string" || !DIGEST.test(doc.digest)', 'typeof doc.digest !== "string"'],
    ['if (!pin.ok) return', 'if (false) return'],
    ['imageryInstalled: imagery !== null,', 'imageryInstalled: false,'],
    ['imagery !== null && entry.imagery !== null && imagery.sha256 !== entry.imagery.sha256', 'imagery !== null && entry.imagery !== null'],
    ['definitionUpdate: marker.digest !== digest', 'definitionUpdate: false']
];

const source = fs.readFileSync(libFile, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "theme-catalog-control-"));
try {
    CONTROLS.forEach(([needle, replacement], index) => {
        const label = "control " + index + " " + JSON.stringify(needle);
        assert.equal(source.split(needle).length, 2, label + ": the text to replace must occur once");
        // One file per control: require caches a module by its path.
        const mutant = path.join(temp, index + ".js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(require(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, label + ": the suite passed on a copy without that rule");
    });
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-theme-catalog: ok accepted=${ACCEPTED.length} refused=${REFUSED.length} states=${STATES.length} controls=${CONTROLS.length}`);
