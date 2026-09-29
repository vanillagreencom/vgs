// The catalog marker bin/vgsh-theme-judge writes into every package `vgsh
// theme install` lands, and the install state `vgsh theme catalog` reports
// for a catalog entry from it. No I/O: the judge reads and writes the
// files and passes their text, with ThemeLogic.js as LOGIC.
//
// The marker is `.vgs-catalog.json` in the installed package's directory,
// `{ "source": "catalog", "digest": <sha256>, "imagery": <pin|null> }`:
// `digest` is the package digest the install or the last catalog update
// wrote, the one applied.json records for the same content, and `imagery`
// the pin of the wallpaper archive unpacked into the package, null until
// one is. docs/architecture/theme-catalog.md § Install.
"use strict";

const MARKER_FILE = ".vgs-catalog.json";
const MARKER_KEYS = ["source", "digest", "imagery"];
const MARKER_SOURCE = "catalog";
const DIGEST = /^[0-9a-f]{64}$/;

// The marker's text for a package of DIGEST whose wallpapers are IMAGERY.
function markerText(digest, imagery) {
    return JSON.stringify({ source: MARKER_SOURCE, digest: digest, imagery: imagery }) + "\n";
}

// Judge TEXT as a marker: `{ ok: true, marker: { digest, imagery } }`, or
// one refusal whose reason is `marker` and whose token names the key.
function acceptMarker(logic, text) {
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return logic.refusal("marker", "", "json=" + JSON.stringify(e.message));
    }
    if (!logic.isPlainObject(doc)) return logic.refusal("marker", "", "got=" + JSON.stringify(doc));
    for (const key of Object.keys(doc))
        if (!MARKER_KEYS.includes(key)) return logic.refusal("marker", "", "key=" + key);
    for (const key of MARKER_KEYS)
        if (!Object.hasOwn(doc, key)) return logic.refusal("marker", "", "key=" + key);
    if (doc.source !== MARKER_SOURCE) return logic.refusal("marker", "source", "got=" + JSON.stringify(doc.source));
    if (typeof doc.digest !== "string" || !DIGEST.test(doc.digest)) return logic.refusal("marker", "digest", "got=" + JSON.stringify(doc.digest));
    if (doc.imagery === null) return { ok: true, marker: { digest: doc.digest, imagery: null } };
    const pin = logic.catalogImagery(doc.imagery, "imagery");
    if (!pin.ok) return logic.refusal("marker", pin.token, pin.detail);
    return { ok: true, marker: { digest: doc.digest, imagery: pin.imagery } };
}

// The install state of catalog ENTRY, an entry ThemeLogic.acceptCatalogIndex
// answered: MARKER is the judged marker of the catalog install of its name,
// or null when none is installed, and DIGEST the catalog package's digest.
// `definitionUpdate` is true when the catalog's package is not the one the
// install landed, `imageryUpdate` when the index pins another archive than
// the one unpacked.
function installState(entry, marker, digest) {
    if (marker === null) return { installed: false, imageryInstalled: false, imageryUpdate: false, definitionUpdate: false };
    const imagery = marker.imagery;
    return {
        installed: true,
        imageryInstalled: imagery !== null,
        imageryUpdate: imagery !== null && entry.imagery !== null && imagery.sha256 !== entry.imagery.sha256,
        definitionUpdate: marker.digest !== digest
    };
}

module.exports = { MARKER_FILE, markerText, acceptMarker, installState };
