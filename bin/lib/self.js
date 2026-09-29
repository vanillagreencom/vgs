// vgsh self: how this VGS tree was installed, what its channel offers now,
// and the update of a curl install (D040). bin/vgsh runs it under node and
// owns the git calls: it hands in whether the tree is its own checkout and,
// for a checkout or a vgs-git package, the commits git read.
//
//   self.js detect <root> <data-home> <version> <checkout>
//       the install method: one line `<method> <package> <current>
//       <manager>`, `-` for an empty field. <checkout> is true when the
//       tree is the top level of its own git checkout.
//   self.js latest <repository>
//       the newest release's version, X.Y.Z, from the GitHub API
//   self.js report text|json <version> <method> <package> <current> <latest> <behind-count> <error>
//       judge `behind` and print the status; `-` is an absent value
//   self.js install <repository> <data-home> <root> <current>
//       replace a curl install by the newest release when it is newer
//
// The methods, judged in this order on the real path of the tree:
//   checkout  the tree is the top level of its own git checkout
//   nix       the tree lies in the Nix store: $NIX_STORE_DIR, else /nix/store
//   curl      <data-home>/vgs/current resolves to the tree, a directory of
//             <data-home>/vgs
//   package   the system's primary package manager owns the tree's VERSION
//             (`vgsh pkg owner`), as the package vgs or vgs-git
// Any other tree is refused as `method=unknown path=<root>`.
//
// The release API is https://api.github.com. VGS_RELEASE_API replaces it
// only in a test run, VGS_TEST_RUN non-empty, and only with a loopback base,
// http://127.0.0.1:<port>; anything else set there is refused. A download
// is https, or on the loopback base's origin.
//
// Every refusal is one line on stderr, `vgsh: refused: <key>=<value>`,
// through bin/lib/judge-files.js, exit 1; a bad invocation exits 2.
// docs/architecture/distribution.md § Install methods.
"use strict";
const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { Readable } = require("stream");
const { pipeline } = require("stream/promises");

const { Refusal, refuse, main, writing } = require(path.join(__dirname, "judge-files.js"));

const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+$/;
// A vgs-git package's version ends in the commit it was built from: the
// AUR form X.Y.Z.r<N>.g<hash> and the COPR form X.Y.Z^<N>.git<hash>.
const GIT_PACKAGE_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:\.r|\^)[0-9]+\.g(?:it)?([0-9a-f]{7,40})$/;
const PACKAGES = ["vgs", "vgs-git"];
const API = "https://api.github.com";
// The seconds the release query may take, and the seconds and bytes one
// download may take. The release archive was 5.5 MB at 0.1.0.
const API_TIMEOUT = 10;
const DOWNLOAD_TIMEOUT = 120;
const MAX_ARCHIVE = 128 * 1024 * 1024;
const MAX_SUMS = 64 * 1024;

function usage(first) {
    process.stderr.write("vgsh: refused: " + first + "\nusage: self.js detect|latest|report|install ...\n");
    process.exit(2);
}

// The real path of FILE, or null when it does not resolve.
function real(file) {
    try {
        return fs.realpathSync(file);
    } catch (e) {
        if (e.code === "ENOENT" || e.code === "ENOTDIR" || e.code === "ELOOP") return null;
        refuse("path=unreadable path=" + file + " error=" + e.code);
    }
}

function inside(file, dir) {
    return dir !== null && file.startsWith(dir.endsWith("/") ? dir : dir + "/");
}

// The package that owns ROOT's VERSION, through `vgsh pkg owner`, the
// package layer's one owner query: `{ manager, package, version }`.
function owner(root) {
    const run = childProcess.spawnSync(process.execPath, [path.join(__dirname, "..", "vgsh-pkg"), "owner", path.join(root, "VERSION")], { encoding: "utf8" });
    if (run.error !== undefined) refuse("pkg=failed error=" + run.error.code);
    if (run.status !== 0) refuse("method=unknown path=" + root, undefined, 1, run.stderr);
    try {
        return JSON.parse(run.stdout);
    } catch (e) {
        refuse("pkg=unreadable output=" + JSON.stringify(run.stdout));
    }
}

// The method line for ROOT, as the header states.
function detect(root, dataHome, version, checkout) {
    if (checkout) return ["checkout", "-", "-", "-"];
    const tree = real(root);
    if (tree === null) refuse("path=unreadable path=" + root);
    if (inside(tree, real(process.env.NIX_STORE_DIR || "/nix/store"))) return ["nix", "-", version, "-"];
    const vgsData = real(path.join(dataHome, "vgs"));
    if (vgsData !== null && real(path.join(vgsData, "current")) === tree && path.dirname(tree) === vgsData) return ["curl", "-", version, "-"];
    const found = owner(tree);
    if (!PACKAGES.includes(found.package)) refuse("package=" + found.package + " manager=" + found.manager + " reason=not-vgs");
    if (found.version === null) refuse("package=" + found.package + " manager=" + found.manager + " reason=version-unknown");
    const pattern = found.package === "vgs" ? VERSION_PATTERN : GIT_PACKAGE_PATTERN;
    if (!pattern.test(found.version)) refuse("package=" + found.package + " version=" + found.version + " reason=not-a-version");
    return ["package", found.package, found.version, found.manager];
}

// Whether version A is newer than version B, both X.Y.Z.
function newer(a, b) {
    const x = a.split(".").map(Number);
    const y = b.split(".").map(Number);
    for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
    return false;
}

// The API base and, for a loopback override, the one origin a download
// may use besides https.
function apiBase() {
    const value = process.env.VGS_RELEASE_API;
    if (value === undefined || value === "") return { base: API, origin: null };
    let url;
    try {
        url = new URL(value);
    } catch (e) {
        url = null;
    }
    if (!process.env.VGS_TEST_RUN || url === null || url.protocol !== "http:" || url.hostname !== "127.0.0.1")
        refuse("release-api=refused value=" + JSON.stringify(value), undefined, 1, "VGS_RELEASE_API is a loopback base for a test run alone");
    return { base: value.replace(/\/+$/, ""), origin: url.origin };
}

// GET URL within SECONDS. KEY leads each refusal: KEY=timeout, KEY=unreachable
// and KEY=http for a status other than 200.
async function get(url, seconds, key, api) {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" && parsed.origin !== api.origin) refuse(key + "=insecure url=" + url);
    let response;
    try {
        response = await fetch(url, { headers: { "Accept": "application/vnd.github+json", "User-Agent": "vgsh" }, redirect: "follow", signal: AbortSignal.timeout(seconds * 1000) });
    } catch (e) {
        if (e.name === "TimeoutError") refuse(key + "=timeout seconds=" + seconds + " url=" + url);
        refuse(key + "=unreachable url=" + url, undefined, 1, String(e.cause || e.message));
    }
    const landed = new URL(response.url || url);
    if (landed.protocol !== "https:" && landed.origin !== api.origin) refuse(key + "=insecure url=" + landed.href);
    return response;
}

// The newest release of REPOSITORY: `{ version, assets }`, assets mapping
// each asset's name to its download URL.
async function latestRelease(repository, api) {
    const url = api.base + "/repos/" + repository + "/releases/latest";
    const response = await get(url, API_TIMEOUT, "release", api);
    if (response.status === 404) refuse("release=none repository=" + repository);
    if (response.status !== 200) refuse("release=http status=" + response.status + " url=" + url);
    let doc;
    try {
        doc = JSON.parse(await response.text());
    } catch (e) {
        refuse("release=malformed url=" + url);
    }
    if (doc === null || typeof doc.tag_name !== "string" || !Array.isArray(doc.assets)) refuse("release=malformed url=" + url);
    const version = doc.tag_name.replace(/^v/, "");
    if (!doc.tag_name.startsWith("v") || !VERSION_PATTERN.test(version)) refuse("tag=" + doc.tag_name + " reason=not-a-version");
    const assets = new Map();
    for (const asset of doc.assets)
        if (asset !== null && typeof asset.name === "string" && typeof asset.browser_download_url === "string") assets.set(asset.name, asset.browser_download_url);
    return { version, assets };
}

// Stream NAME's download from RELEASE into FILE, refusing past MAX bytes.
// Answers the file's sha256 in hex.
async function download(release, name, file, max, api) {
    const url = release.assets.get(name);
    if (url === undefined) refuse("asset=missing name=" + name + " release=v" + release.version);
    const response = await get(url, DOWNLOAD_TIMEOUT, "download", api);
    if (response.status !== 200 || response.body === null) refuse("download=http status=" + response.status + " url=" + url);
    const hash = crypto.createHash("sha256");
    let bytes = 0;
    try {
        await pipeline(Readable.fromWeb(response.body), async function* (chunks) {
            for await (const chunk of chunks) {
                bytes += chunk.length;
                if (bytes > max) refuse("download=too-large name=" + name + " limit=" + max);
                hash.update(chunk);
                yield chunk;
            }
        }, fs.createWriteStream(file, { flags: "wx" }));
    } catch (e) {
        if (e.name === "TimeoutError") refuse("download=timeout seconds=" + DOWNLOAD_TIMEOUT + " url=" + url);
        if (e instanceof Refusal) throw e;
        refuse("download=failed url=" + url, undefined, 1, String(e.message));
    }
    return hash.digest("hex");
}

// The sha256 SHA256SUMS lists for NAME: exactly one `<hex>  <name>` or
// `<hex> *<name>` line.
function listedSum(text, name) {
    const sums = [];
    for (const line of text.split("\n")) {
        const m = /^([0-9a-f]{64}) [ *](.+)$/.exec(line);
        if (m !== null && m[2] === name) sums.push(m[1]);
    }
    if (sums.length !== 1) refuse("checksum=unlisted name=" + name + " count=" + sums.length);
    return sums[0];
}

function run(argv, options, key) {
    const r = childProcess.spawnSync(argv[0], argv.slice(1), Object.assign({ encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }, options));
    if (r.error !== undefined) refuse(key + " error=" + r.error.code);
    if (r.status !== 0) refuse(key + " exit=" + (r.status === null ? r.signal : r.status), undefined, 1, r.stdout + r.stderr);
}

// Replace the curl install whose data directory is DATA and whose running
// tree ROOT holds version CURRENT by REPOSITORY's newest release, when it is
// newer. The release is staged under DATA, checked against its SHA256SUMS,
// installed by its own packaging/install-system.sh, moved to DATA/<version>
// and made current by renaming a new `current` link over the old one. The
// tree that was current stays; every other version directory is removed.
// bin/vgsh holds DATA/.self.lock around the call.
async function install(repository, dataHome, root, current) {
    const data = path.join(dataHome, "vgs");
    const api = apiBase();
    const release = await latestRelease(repository, api);
    if (!newer(release.version, current)) {
        process.stdout.write("ok up-to-date=vgs version=" + current + "\n");
        return;
    }
    const target = path.join(data, release.version);
    let taken = true;
    try {
        fs.lstatSync(target);
    } catch (e) {
        if (e.code !== "ENOENT") refuse("target=unreadable path=" + target + " error=" + e.code);
        taken = false;
    }
    if (taken) refuse("target=exists path=" + target, undefined, 1, "remove it and run vgsh self update again");
    let stage;
    writing(data, "data", () => {
        // Under the lock, a staging directory left behind is a dead run's.
        for (const entry of fs.readdirSync(data))
            if (entry.startsWith(".self-update-")) fs.rmSync(path.join(data, entry), { recursive: true, force: true });
        stage = fs.mkdtempSync(path.join(data, ".self-update-"));
    });
    try {
        const archive = "vgs-" + release.version + ".tar.gz";
        const sums = path.join(stage, "SHA256SUMS");
        await download(release, "SHA256SUMS", sums, MAX_SUMS, api);
        const got = await download(release, archive, path.join(stage, archive), MAX_ARCHIVE, api);
        const want = listedSum(fs.readFileSync(sums, "utf8"), archive);
        if (got !== want) refuse("checksum=mismatch name=" + archive + " want=" + want + " got=" + got);
        const source = path.join(stage, "source");
        writing(source, "stage", () => fs.mkdirSync(source));
        run(["tar", "-xzf", path.join(stage, archive), "-C", source], {}, "archive=unpack name=" + archive);
        const top = fs.readdirSync(source);
        const unpacked = path.join(source, "vgs-" + release.version);
        if (top.length !== 1 || top[0] !== "vgs-" + release.version || !fs.lstatSync(unpacked).isDirectory())
            refuse("archive=layout name=" + archive + " top=" + JSON.stringify(top));
        let shipped;
        try {
            shipped = fs.readFileSync(path.join(unpacked, "VERSION"), "utf8");
        } catch (e) {
            refuse("archive=layout name=" + archive + " version=missing");
        }
        if (shipped !== release.version + "\n") refuse("archive=version name=" + archive + " version=" + JSON.stringify(shipped));
        const destdir = path.join(stage, "tree");
        run(["bash", path.join(unpacked, "packaging", "install-system.sh")], { env: Object.assign({}, process.env, { DESTDIR: destdir, PREFIX: "/vgs" }) }, "install=failed name=" + archive);
        writing(target, "target", () => fs.renameSync(path.join(destdir, "vgs", "share", "vgs"), target));
        const link = path.join(stage, "current");
        writing(path.join(data, "current"), "current", () => {
            fs.symlinkSync(release.version, link);
            fs.renameSync(link, path.join(data, "current"));
        });
    } finally {
        fs.rmSync(stage, { recursive: true, force: true });
    }
    const previous = path.basename(root);
    writing(data, "prune", () => {
        for (const entry of fs.readdirSync(data)) {
            if (!VERSION_PATTERN.test(entry) || entry === release.version || entry === previous) continue;
            const dir = path.join(data, entry);
            if (fs.lstatSync(dir).isDirectory()) fs.rmSync(dir, { recursive: true, force: true });
        }
    });
    process.stdout.write("ok updated=vgs from=" + current + " to=" + release.version + " path=" + target + "\n");
}

// `behind` from the facts bin/vgsh gathered: a checkout is behind while its
// upstream holds commits it lacks, a vgs-git package while main is not the
// commit it was built from, and every other install while the newest
// release is newer than its version. null when an error stopped the read.
function behind(method, pkg, current, latest, count) {
    if (method === "checkout") return Number(count) > 0;
    if (pkg === "vgs-git") return !latest.startsWith(GIT_PACKAGE_PATTERN.exec(current)[1]);
    return newer(latest, current);
}

function report(format, fields) {
    const [version, method, pkg, current, latest, count, error] = fields.map(v => (v === "-" || v === "" ? null : v));
    const status = { version, method, package: pkg, current, latest, behind: null, error };
    if (error === null) status.behind = behind(method, pkg, current, latest, count);
    else status.latest = null;
    if (format === "json") {
        process.stdout.write(JSON.stringify(status) + "\n");
        return;
    }
    const words = [];
    for (const key of ["version", "method", "package", "current", "latest", "behind", "error"])
        if (status[key] !== null) words.push(key + "=" + status[key]);
    process.stdout.write(words.join(" ") + "\n");
}

const [verb, ...args] = process.argv.slice(2);
main(() => {
    switch (verb) {
    case "detect":
        if (args.length !== 4 || !["true", "false"].includes(args[3])) usage("detect-arguments=" + JSON.stringify(args));
        process.stdout.write(detect(args[0], args[1], args[2], args[3] === "true").join(" ") + "\n");
        return undefined;
    case "latest":
        if (args.length !== 1) usage("latest-arguments=" + JSON.stringify(args));
        return latestRelease(args[0], apiBase()).then(r => process.stdout.write(r.version + "\n"));
    case "report":
        if (args.length !== 8 || !["text", "json"].includes(args[0])) usage("report-arguments=" + JSON.stringify(args));
        report(args[0], args.slice(1));
        return undefined;
    case "install":
        if (args.length !== 4) usage("install-arguments=" + JSON.stringify(args));
        return install(args[0], args[1], args[2], args[3]);
    default:
        usage("self-subcommand=" + (verb === undefined ? "missing" : verb));
    }
    return undefined;
});
