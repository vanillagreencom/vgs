// The background state bin/vgsh-theme-judge keeps for `vgsh theme apply`
// and `vgsh theme background next`, `previous` and `set`: the images a
// package's backgrounds/ or the user folder holds, the remembered image
// per theme, the current image and each screen's own image, in the state
// directory as backgrounds.json and the `background` symlink.
//
// backgrounds.json is `{ "schemaVersion": 1, "current": <path|null>,
// "stamp": <string|null>, "themes": { "<theme>": "<file>" }, "screens":
// { "<output>": { "path": <path>, "stamp": <string> } } }`: `current` is
// the absolute path of the image the `background` symlink names, which the
// vgs.themes plugin draws, `stamp` that file's size and modification time,
// so an image replaced under its name rewrites the file and the plugin
// decodes it again, `themes` the image `next`, `previous` or `set` last
// chose for each theme, and `screens` the image `set --screen` chose for
// one Hyprland output, stamped the same way. `screens` is written only
// while it holds an output, so a file without it is a current file with
// no screen image (D039). An absent file is no current image, nothing
// remembered and no screen image; a state that is all three is written as
// no file. The judge is this file's only writer:
// docs/architecture/theme-backgrounds.md.
"use strict";
const fs = require("fs");
const path = require("path");
const { refuse, readJson, writing, replaceFile } = require(path.join(__dirname, "judge-files.js"));

const DIR = "backgrounds";
const STATE_FILE = "backgrounds.json";
const LINK = "background";
// What the shell's Image reads with the image plugins Qt ships by default.
const EXTENSIONS = [".png", ".jpg", ".jpeg"];
// A Hyprland output name as `hyprctl monitors` prints it and Quickshell's
// `screen.name` carries it: `DP-1`, `HDMI-A-1`, `eDP-1`, `HEADLESS-2`.
const OUTPUT_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

// Whether NAME can be one image of a backgrounds/ directory: a file name,
// not hidden, with an image extension in any case.
function isImageName(name) {
    return typeof name === "string" && name !== "" && !name.includes("/") && !name.startsWith(".") &&
        EXTENSIONS.includes(path.extname(name).toLowerCase());
}

function isOutputName(name) {
    return typeof name === "string" && OUTPUT_NAME.test(name);
}

// What entry NAME of a backgrounds/ directory is, STAT its lstat or a
// Dirent, null when nothing stands there: `image`, or the reason it is
// none, `not-an-image`, `absent`, `symlink` or `not-a-file`. No package
// contributes a symlink below its own directory (D031), and the user
// folder is read by the same rule.
function entryKind(name, stat) {
    if (!isImageName(name)) return "not-an-image";
    if (stat === null) return "absent";
    if (stat.isSymbolicLink()) return "symlink";
    return stat.isFile() ? "image" : "not-a-file";
}

// The lstat of FILE, or null when it or a directory above it is absent;
// KEY leads the refusal for any other failure.
function lstatOrNull(file, key) {
    try {
        return fs.lstatSync(file);
    } catch (e) {
        if (e.code === "ENOENT" || e.code === "ENOTDIR") return null;
        refuse(key + "=unreadable path=" + file + " error=" + e.code, "unreadable");
    }
}

// Whether BASE, a backgrounds/ directory, is a symlink, which holds no
// image. KEY leads the refusal for one that cannot be read.
function linkedFolder(base, key) {
    const stat = lstatOrNull(base, key);
    return stat !== null && stat.isSymbolicLink();
}

// The absolute path of image FILE in DIR's backgrounds/, as the state,
// the link and `background list` name it.
function imagePath(dir, file) {
    return path.resolve(dir, DIR, file);
}

// The image file names in DIR's backgrounds/, sorted: each one entryKind
// answers `image` for. A symlinked backgrounds/ holds none, as an absent
// one does; KEY leads the refusal for one that cannot be read, so no apply
// lands a background chosen from part of the list.
function images(dir, key) {
    const base = path.join(dir, DIR);
    if (linkedFolder(base, key)) return [];
    try {
        return fs.readdirSync(base, { withFileTypes: true })
            .filter(entry => entryKind(entry.name, entry) === "image")
            .map(entry => entry.name)
            .sort();
    } catch (e) {
        if (e.code === "ENOENT") return [];
        refuse(key + "=unreadable path=" + base + " error=" + e.code, "unreadable");
    }
}

// The real path of FILE, or null when it or a directory above it is
// absent; KEY leads the refusal for any other failure.
function realOrNull(file, key) {
    try {
        return fs.realpathSync(file);
    } catch (e) {
        if (e.code === "ENOENT" || e.code === "ENOTDIR") return null;
        refuse(key + "=unreadable path=" + file + " error=" + e.code, "unreadable");
    }
}

// The source among SOURCES, `[{ theme, dir }]`, whose backgrounds/ holds
// ARGUMENT, a path relative to the working directory, as `{ source,
// background }`, the image's file name: exactly an image `images` lists
// for that source. The directory above backgrounds/ matches a source by
// real path, so a symlink above it reaches the same source; nothing at or
// below backgrounds/ is followed. KEY leads the refusal: `outside` for a
// path in no source's backgrounds/, else the entryKind reason or
// `symlink` for a symlinked backgrounds/.
function locate(sources, argument, key) {
    const at = path.resolve(argument);
    const base = path.dirname(at);
    const background = path.basename(at);
    const parent = path.basename(base) === DIR ? realOrNull(path.dirname(base), key) : null;
    const source = parent === null ? undefined : sources.find(s => realOrNull(s.dir, key) === parent);
    if (source === undefined) refuse(key + "=outside path=" + at, "outside");
    const folder = path.join(source.dir, DIR);
    if (linkedFolder(folder, key)) refuse(key + "=symlink path=" + folder, "symlink");
    const file = path.join(folder, background);
    const kind = entryKind(background, lstatOrNull(file, key));
    if (kind !== "image") refuse(key + "=" + kind + " path=" + file, kind);
    return { source, background };
}

// Image FILE of DIR's backgrounds/ as the state names it, `{ path, stamp }`,
// or null when FILE is null. KEY leads the refusal for an image that
// cannot be read.
function stamped(dir, file, key) {
    if (file === null) return null;
    const at = imagePath(dir, file);
    try {
        const stat = fs.statSync(at);
        return { path: at, stamp: stat.size + ":" + stat.mtimeMs };
    } catch (e) {
        refuse(key + "=unreadable path=" + at + " error=" + e.code, "unreadable");
    }
}

// The state STATE_DIR's backgrounds.json holds, as `{ current, themes,
// screens }`: `current` stamped's `{ path, stamp }` or null, `themes` and
// `screens` in name order, judged with LOGIC, shell/Commons/ThemeLogic.js.
// KEY leads the refusal for a file that cannot be read or parsed, or is
// not the shape the header states.
function read(logic, stateDir, key) {
    const file = path.join(stateDir, STATE_FILE);
    const doc = readJson(file, key, true);
    if (doc === null) return { current: null, themes: {}, screens: {} };
    const isShown = (at, stamp) => typeof at === "string" && path.isAbsolute(at) && typeof stamp === "string";
    const isScreen = ([name, shown]) => isOutputName(name) && logic.isPlainObject(shown) &&
        Object.keys(shown).length === 2 && isShown(shown.path, shown.stamp);
    const shaped = logic.isPlainObject(doc) && doc.schemaVersion === 1 &&
        Object.keys(doc).length === (Object.hasOwn(doc, "screens") ? 5 : 4) &&
        ((doc.current === null && doc.stamp === null) || isShown(doc.current, doc.stamp)) &&
        logic.isPlainObject(doc.themes) && Object.values(doc.themes).every(isImageName) &&
        (!Object.hasOwn(doc, "screens") || (logic.isPlainObject(doc.screens) && Object.entries(doc.screens).every(isScreen)));
    if (!shaped) refuse(key + "=malformed path=" + file, "malformed");
    const screens = {};
    for (const [name, shown] of Object.entries(doc.screens || {})) screens[name] = { path: shown.path, stamp: shown.stamp };
    return {
        current: doc.current === null ? null : { path: doc.current, stamp: doc.stamp },
        themes: sortedKeys(doc.themes),
        screens: sortedKeys(screens)
    };
}

function sortedKeys(object) {
    const out = {};
    for (const name of Object.keys(object).sort()) out[name] = object[name];
    return out;
}

// STATE as backgrounds.json holds it; `screens` only while it names an
// output.
function document(state) {
    const doc = {
        schemaVersion: 1,
        current: state.current === null ? null : state.current.path,
        stamp: state.current === null ? null : state.current.stamp,
        themes: sortedKeys(state.themes)
    };
    if (Object.keys(state.screens).length > 0) doc.screens = sortedKeys(state.screens);
    return doc;
}

// The image a theme shows among IMAGES: REMEMBERED while the package still
// holds it, else the first, or null when it holds none.
function choose(list, remembered) {
    if (list.includes(remembered)) return remembered;
    return list.length === 0 ? null : list[0];
}

// Make AFTER, a state as `read` answers it, the background state: the
// `background` symlink to its `current` first, replaced by rename, then
// backgrounds.json when it differs from BEFORE, the state `read` answered.
// The state directory is created first: `set` can be the first command a
// fresh home runs. KEY leads the refusal for each write that fails.
function land(stateDir, after, before, key) {
    writing(stateDir, key, () => fs.mkdirSync(stateDir, { recursive: true }));
    const link = path.join(stateDir, LINK);
    const current = after.current === null ? null : after.current.path;
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
    const doc = JSON.stringify(document(after));
    if (doc === JSON.stringify(document(before))) return;
    const state = path.join(stateDir, STATE_FILE);
    const empty = current === null && Object.keys(after.themes).length === 0 && Object.keys(after.screens).length === 0;
    if (empty) writing(state, key, () => fs.rmSync(state, { force: true }));
    else replaceFile(state, doc + "\n", key);
}

module.exports = { DIR, STATE_FILE, LINK, isOutputName, images, imagePath, locate, stamped, read, choose, land };
