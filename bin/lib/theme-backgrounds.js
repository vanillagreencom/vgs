// The background state bin/vgsh-theme-judge keeps for `vgsh theme apply`
// and `vgsh theme background next`: the images a package's backgrounds/
// holds, the remembered image per theme and the current image, in the
// state directory as backgrounds.json and the `background` symlink.
//
// backgrounds.json is `{ "schemaVersion": 1, "current": <path|null>,
// "stamp": <string|null>, "themes": { "<theme>": "<file>" } }`: `current`
// is the absolute path of the image the `background` symlink names, which
// the vgs.background plugin draws, `stamp` that file's size and
// modification time, so an image replaced under its name rewrites the file
// and the plugin decodes it again, and `themes` the image `next` last chose
// for each theme. An absent file is no current image and nothing
// remembered; a state that is both is written as no file. The judge is
// this file's only writer: docs/architecture/theme-backgrounds.md.
"use strict";
const fs = require("fs");
const path = require("path");
const { refuse, readJson, writing, replaceFile } = require(path.join(__dirname, "judge-files.js"));

const DIR = "backgrounds";
const STATE_FILE = "backgrounds.json";
const LINK = "background";
// What the shell's Image reads with the image plugins Qt ships by default.
const EXTENSIONS = [".png", ".jpg", ".jpeg"];

// Whether NAME can be one image of a backgrounds/ directory: a file name,
// not hidden, with an image extension in any case.
function isImageName(name) {
    return typeof name === "string" && name !== "" && !name.includes("/") && !name.startsWith(".") &&
        EXTENSIONS.includes(path.extname(name).toLowerCase());
}

// The image file names in package directory PKG's backgrounds/, sorted:
// each a file, or a symlink to one, whose name isImageName accepts. An
// absent directory holds none; KEY leads the refusal for one that cannot
// be read, so no apply lands a background chosen from part of the list.
function images(pkg, key) {
    const base = path.join(pkg, DIR);
    try {
        return fs.readdirSync(base, { withFileTypes: true })
            .filter(entry => isImageName(entry.name) && (entry.isFile() ||
                (entry.isSymbolicLink() && fs.statSync(path.join(base, entry.name), { throwIfNoEntry: false })?.isFile() === true)))
            .map(entry => entry.name)
            .sort();
    } catch (e) {
        if (e.code === "ENOENT") return [];
        refuse(key + "=unreadable path=" + base + " error=" + e.code, "unreadable");
    }
}

// The state STATE_DIR's backgrounds.json holds, as { current, stamp, themes },
// `themes` in name order, judged with LOGIC, shell/Commons/ThemeLogic.js.
// KEY leads the refusal for a file that cannot be read or parsed, or is not
// the shape the header states.
function read(logic, stateDir, key) {
    const file = path.join(stateDir, STATE_FILE);
    const doc = readJson(file, key, true);
    if (doc === null) return { current: null, stamp: null, themes: {} };
    const shaped = logic.isPlainObject(doc) && Object.keys(doc).length === 4 && doc.schemaVersion === 1 &&
        ((doc.current === null && doc.stamp === null) ||
            (typeof doc.current === "string" && path.isAbsolute(doc.current) && typeof doc.stamp === "string")) &&
        logic.isPlainObject(doc.themes) && Object.values(doc.themes).every(isImageName);
    if (!shaped) refuse(key + "=malformed path=" + file, "malformed");
    return { current: doc.current, stamp: doc.stamp, themes: sortedKeys(doc.themes) };
}

function sortedKeys(object) {
    const out = {};
    for (const name of Object.keys(object).sort()) out[name] = object[name];
    return out;
}

// The image a theme shows among IMAGES: REMEMBERED while the package still
// holds it, else the first, or null when it holds none.
function choose(list, remembered) {
    if (list.includes(remembered)) return remembered;
    return list.length === 0 ? null : list[0];
}

// Make FILE of package directory PKG, or no image when FILE is null, the
// current background: the `background` symlink first, replaced by rename,
// then backgrounds.json with THEMES, the remembered images, when it differs
// from BEFORE, the state `read` answered. Answers the image's path or null.
// An image that cannot be read refuses under KEY, as does each write that
// fails.
function land(stateDir, pkg, file, themes, before, key) {
    const link = path.join(stateDir, LINK);
    const current = file === null ? null : path.resolve(pkg, DIR, file);
    let stamp = null;
    if (current !== null) {
        try {
            const stat = fs.statSync(current);
            stamp = stat.size + ":" + stat.mtimeMs;
        } catch (e) {
            refuse(key + "=unreadable path=" + current + " error=" + e.code, "unreadable");
        }
    }
    writing(link, key, () => {
        let named = null;
        try {
            named = fs.readlinkSync(link);
        } catch (e) {
            // EINVAL: something other than a symlink stands there.
            if (e.code !== "ENOENT" && e.code !== "EINVAL") throw e;
        }
        if (current === null) {
            fs.rmSync(link, { force: true });
            return;
        }
        if (named === current) return;
        const tmp = link + ".vgsh-" + process.pid;
        fs.rmSync(tmp, { force: true });
        fs.symlinkSync(current, tmp);
        try {
            fs.renameSync(tmp, link);
        } catch (e) {
            fs.rmSync(tmp, { force: true });
            throw e;
        }
    });
    const sorted = sortedKeys(themes);
    const after = { current, stamp, themes: sorted };
    if (JSON.stringify(after) === JSON.stringify(before)) return current;
    const state = path.join(stateDir, STATE_FILE);
    if (current === null && Object.keys(sorted).length === 0) writing(state, key, () => fs.rmSync(state, { force: true }));
    else replaceFile(state, JSON.stringify(Object.assign({ schemaVersion: 1 }, after)) + "\n", key);
    return current;
}

module.exports = { DIR, STATE_FILE, LINK, images, read, choose, land };
