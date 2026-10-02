#!/usr/bin/env node
// The vision executor (Vision.js) and its geometry judge (Screen.js) through
// the real registration seam, desktop session reader, router, Session, Policy
// and Audit in the J09 world. grim, slurp and tesseract are
// scripts/fixtures/jarvis/vision-tool.py, which draws grim's image from the
// stand-in hyprctl's own state; magick is the host's ImageMagick, run by that
// stand-in on fixture files only. No compositor, screen, device or network
// is reached. Each control edits a disposable copy of one backend file.
"use strict";
const crypto = require("node:crypto");
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { load } = require("../bin/lib/qml-library.js");
const { commandFile } = require("../bin/lib/judge-files.js");
const Desk = require("./fixtures/jarvis/desktop.js");
const { BACKGROUND, monitor, client, world: screenWorld, decode } = require("./fixtures/jarvis/vision.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = name => path.join(backend, name);
const STANDINS = ["grim", "slurp", "tesseract", "magick"];
const MAGICK = ["/usr/bin/magick", "/bin/magick"];
const SHIPPED = JSON.parse(fs.readFileSync(path.join(tree, "shell/plugins/vgs.jarvis/manifest.json"), "utf8")).settings.privateWindows;
const OCR = ["--oem", "1", "--psm", "3", "--dpi", "300", "-l", "eng", "-c", "preserve_interword_spaces=1"];
const sha = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
// The picture a completed result carries, asserted present.
function picture(value, label) {
    assert.ok(value.image !== undefined, label + ": the result carries the image");
    return value.image.item.content;
}

const BLACK = [0, 0, 0, 255], BG = [...BACKGROUND, 255];
const RED = [200, 40, 40], GREEN = [40, 200, 40], BLUE = [40, 40, 200];
const COLORS = { "0xa1": RED, "0xb2": GREEN, "0xc3": BLUE };
const secret = (address, at, size, values = {}) => client(address, { class: "Bitwarden", initialClass: "Bitwarden",
    title: "Vault", initialTitle: "Vault", at, size, ...values });
const plain = (address, at, size, values = {}) => client(address, { class: "foot", initialClass: "foot",
    title: "shell", initialTitle: "shell", at, size, ...values });
const one = (values, box) => ({ monitors: [monitor(0, "FIX-1", values)], outputs: [{ name: "FIX-1", box }] });
const flat = one({ width: 320, height: 200, scale: 1 }, [0, 0, 320, 200]);

// [name, screen, clients, call, the capture's audited facts, pixel probes].
// Each output's layout box is the mode turned for an odd transform, over
// the scale, written by hand. Masks are image pixels, end exclusive.
const MASKS = [
    ["scale-1", flat, [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])],
        ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 320, 200], scale: 1, width: 320, height: 200, masks: 1 },
        [[20, 30, BLACK], [119, 79, BLACK], [70, 55, BLACK], [19, 30, BG], [120, 79, BG], [70, 80, BG], [160, 50, [...GREEN, 255]], [249, 119, [...GREEN, 255]]]],
    ["scale-2", one({ width: 640, height: 400, scale: 2 }, [0, 0, 320, 200]), [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])],
        ["vision.monitor", { monitor: "0" }], { box: [0, 0, 320, 200], scale: 2, width: 640, height: 400, masks: 1 },
        [[40, 60, BLACK], [239, 159, BLACK], [39, 60, BG], [240, 100, BG], [100, 159, BLACK], [100, 160, BG], [300, 80, [...GREEN, 255]], [499, 239, [...GREEN, 255]]]],
    ["rotated", one({ width: 320, height: 200, scale: 1, transform: 1 }, [0, 0, 200, 320]),
        [plain("0xb2", [20, 20], [150, 100]), secret("0xa1", [20, 220], [100, 60])],
        ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 200, 320], scale: 1, width: 200, height: 320, masks: 1 },
        [[20, 220, BLACK], [119, 279, BLACK], [60, 219, BG], [60, 280, BG], [120, 250, BG], [100, 60, [...GREEN, 255]]]],
    ["flipped-rotated-scale-2", one({ width: 640, height: 400, scale: 2, transform: 5 }, [0, 0, 200, 320]),
        [plain("0xb2", [20, 20], [150, 100]), secret("0xa1", [20, 220], [100, 60])],
        ["vision.screen", {}], { box: [0, 0, 200, 320], scale: 2, width: 400, height: 640, masks: 1 },
        [[40, 440, BLACK], [239, 559, BLACK], [39, 440, BG], [240, 500, BG], [100, 560, BG], [100, 100, [...GREEN, 255]]]],
    ["upside-down", one({ width: 320, height: 200, scale: 1, transform: 2 }, [0, 0, 320, 200]),
        [secret("0xa1", [20, 30], [100, 50])],
        ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 320, 200], scale: 1, width: 320, height: 200, masks: 1 },
        [[20, 30, BLACK], [119, 79, BLACK], [200, 150, BG]]],
    // 1.25 rounds each mask outward, past the stand-in's centre rule.
    ["fractional", one({ width: 400, height: 250, scale: 1.25 }, [0, 0, 320, 200]),
        [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [21, 31], [99, 49])],
        ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 320, 200], scale: 1.25, width: 400, height: 250, masks: 1 },
        [[26, 39, BLACK], [149, 99, BLACK], [60, 38, BLACK], [150, 60, BG], [25, 60, BG], [60, 100, BG], [200, 80, [...GREEN, 255]]]],
    ["screen-two-scales", { monitors: [monitor(0, "FIX-1", { width: 320, height: 200, scale: 1 }),
        monitor(1, "FIX-2", { x: 320, width: 640, height: 400, scale: 2 })],
    outputs: [{ name: "FIX-1", box: [0, 0, 320, 200] }, { name: "FIX-2", box: [320, 0, 320, 200] }] },
    [plain("0xb2", [20, 20], [100, 100]), secret("0xa1", [400, 50], [80, 40], { monitor: 1, workspace: { id: 2, name: "2" } })],
    ["vision.screen", {}], { box: [0, 0, 640, 200], scale: 2, width: 1280, height: 400, masks: 1 },
    [[800, 100, BLACK], [959, 179, BLACK], [799, 140, BG], [960, 140, BG], [900, 180, BG], [100, 100, [...GREEN, 255]]]],
    ["window", flat, [plain("0xb2", [100, 40], [100, 80]), secret("0xa1", [150, 60], [100, 50])],
        ["vision.window", { window: "0xB2" }], { box: [100, 40, 100, 80], scale: 1, width: 100, height: 80, masks: 1 },
        [[50, 20, BLACK], [99, 69, BLACK], [49, 30, [...GREEN, 255]], [60, 70, [...GREEN, 255]], [10, 10, [...GREEN, 255]]]],
    ["region", one({ width: 640, height: 400, scale: 2 }, [0, 0, 320, 200]),
        [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])],
        ["vision.region", { x: 10, y: 10, width: 200, height: 100 }], { box: [10, 10, 200, 100], scale: 2, width: 400, height: 200, masks: 1 },
        [[20, 40, BLACK], [219, 139, BLACK], [19, 60, BG], [220, 60, BG], [300, 100, [...GREEN, 255]]]],
    // A private window on a workspace no monitor shows is painted too.
    ["hidden-workspace", flat, [plain("0xb2", [150, 40], [100, 80]),
        secret("0xa1", [20, 30], [100, 50], { visible: false, workspace: { id: 7, name: "7" } })],
    ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 320, 200], scale: 1, width: 320, height: 200, masks: 1 },
    [[20, 30, BLACK], [119, 79, BLACK]]],
    ["no-private", flat, [plain("0xb2", [150, 40], [100, 80])],
        ["vision.monitor", { monitor: "FIX-1" }], { box: [0, 0, 320, 200], scale: 1, width: 320, height: 200, masks: 0 },
        [[160, 50, [...GREEN, 255]], [20, 30, BG]]]
];

// [name, screen, clients, call, refusal]: plans refused before any capture.
const REFUSALS = [
    ["monitor-absent", flat, [], ["vision.monitor", { monitor: "NOPE" }], "monitor-absent"],
    ["monitor-shape", one({ width: 320, height: 200, scale: 1, transform: 8 }, [0, 0, 320, 200]), [], ["vision.screen", {}], "monitor-shape"],
    ["window-absent", flat, [plain("0xb2", [0, 0], [10, 10])], ["vision.window", { window: "0xdead" }], "window-absent"],
    ["window-hidden", flat, [plain("0xb2", [0, 0], [10, 10], { workspace: { id: 3, name: "3" } })], ["vision.window", { window: "0xb2" }], "window-hidden"],
    ["private-window", flat, [secret("0xa1", [0, 0], [10, 10])], ["vision.window", { window: "0xa1" }], "private-window"],
    ["region-off-screen", flat, [], ["vision.region", { x: 300, y: 150, width: 100, height: 100 }], "region-off-screen"],
    // Inside the screen's bounding box, below the shorter of two monitors.
    ["region-gap", { monitors: [monitor(0, "FIX-1", { width: 320, height: 200, scale: 1 }),
        monitor(1, "FIX-2", { x: 320, width: 320, height: 400, scale: 1 })],
    outputs: [{ name: "FIX-1", box: [0, 0, 320, 200] }, { name: "FIX-2", box: [320, 0, 320, 400] }] }, [],
    ["vision.region", { x: 0, y: 250, width: 50, height: 50 }], "region-off-screen"]
];

// [name, transforms, the output's mode, position and scale, its layout box,
// the image size, a private window's layout rectangle, its mask]: the pure
// judge for every wl_output transform. Boxes, sizes and masks are written by
// hand: an odd transform turns the mode, the scale divides it and rounds,
// and a mask is the window's offset from the box times the scale, rounded
// outward, whatever the transform.
const GEOMETRY = [
    ["upright-scale-1", [0, 2, 4, 6], { width: 1920, height: 1080, scale: 1 }, [0, 0, 1920, 1080], [1920, 1080],
        [100, 50, 200, 100], { x0: 100, y0: 50, x1: 300, y1: 150 }],
    ["turned-scale-1", [1, 3, 5, 7], { width: 1920, height: 1080, scale: 1 }, [0, 0, 1080, 1920], [1080, 1920],
        [100, 50, 200, 100], { x0: 100, y0: 50, x1: 300, y1: 150 }],
    ["upright-scale-2", [0, 2, 4, 6], { width: 1920, height: 1080, scale: 2 }, [0, 0, 960, 540], [1920, 1080],
        [100, 50, 200, 100], { x0: 200, y0: 100, x1: 600, y1: 300 }],
    ["turned-scale-2", [1, 3, 5, 7], { width: 1920, height: 1080, scale: 2 }, [0, 0, 540, 960], [1080, 1920],
        [100, 50, 200, 100], { x0: 200, y0: 100, x1: 600, y1: 300 }],
    ["upright-scale-1.5", [0, 2, 4, 6], { width: 1920, height: 1080, scale: 1.5 }, [0, 0, 1280, 720], [1920, 1080],
        [100, 50, 200, 100], { x0: 150, y0: 75, x1: 450, y1: 225 }],
    ["turned-scale-1.5", [1, 3, 5, 7], { width: 1920, height: 1080, scale: 1.5 }, [0, 0, 720, 1280], [1080, 1920],
        [100, 50, 200, 100], { x0: 150, y0: 75, x1: 450, y1: 225 }],
    // 1366 / 1.5 is 910.67: Hyprland rounds to 911, where a floor gives 910.
    ["rounded-scale-1.5", [0, 2, 4, 6], { width: 1366, height: 768, scale: 1.5 }, [0, 0, 911, 512], [1366, 768],
        [800, 400, 200, 200], { x0: 1200, y0: 600, x1: 1366, y1: 768 }],
    ["turned-rounded-scale-1.5", [1, 3, 5, 7], { width: 1366, height: 768, scale: 1.5 }, [0, 0, 512, 911], [768, 1366],
        [400, 800, 200, 200], { x0: 600, y0: 1200, x1: 768, y1: 1366 }],
    ["fractional-offset", [0], { x: 1920, y: 120, width: 2560, height: 1440, scale: 1.25 }, [1920, 120, 2048, 1152], [2560, 1440],
        [2021, 171, 99, 49], { x0: 126, y0: 63, x1: 250, y1: 125 }]
];

async function main() {
    const real = MAGICK.find(candidate => fs.existsSync(candidate));
    if (real === undefined) {
        console.log("test-jarvis-vision: status=not-measured missing=magick");
        process.exitCode = 77;
        return;
    }
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const Dispatch = load(path.join(tree, "shell/Core/Dispatch.js"));
    const Launch = load(path.join(tree, "shell/Commons/DesktopLaunch.js"));
    const root = process.env.JARVIS_TEST_ROOT;
    const runtime = process.env.XDG_RUNTIME_DIR;
    const screen = screenWorld(runtime, root);
    const directory = path.join(runtime, "vgs/jarvis/vision");
    const ENVIRONMENT = { ...process.env, WAYLAND_DISPLAY: "wayland-fixture", VGSH_RUNNER_PID: "4242", OPENAI_API_KEY: "sk-fixture-secret" };
    const fixed = { PATH: process.env.PATH, LC_ALL: "C.UTF-8" };
    const EXPECTED_ENV = { grim: { ...fixed, XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: "wayland-fixture" },
        slurp: { ...fixed, XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: "wayland-fixture" },
        magick: { ...fixed, MAGICK_TEMPORARY_PATH: directory }, tesseract: fixed };
    const HYPRLAND = { PATH: process.env.PATH, LANG: "C.UTF-8", XDG_RUNTIME_DIR: runtime };
    const CLOCK = { now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) };
    // A turn the user started, whose action is running: the direct calls' state.
    const RUNNING = { turn: { kind: "thinking", gen: 1, op: 5 }, action: { kind: "running", gen: 1, op: 6, brain: 5 } };
    const allow = () => screen.locked() ? { kind: "refuse", reason: "session-locked" } : { kind: "allow" };
    const calls = name => screen.calls().filter(call => call.name === name);
    const hyprctlReads = () => fs.existsSync(path.join(runtime, "hyprctl.log"))
        ? fs.readFileSync(path.join(runtime, "hyprctl.log"), "utf8").split("\n").filter(Boolean).length : 0;
    const left = () => fs.existsSync(directory) ? fs.readdirSync(directory) : [];
    const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

    /**
     * The real seam, router, reducer and audit writer, as jarvisd builds
     * them. state replaces Session's record for the executor's own turn
     * read; route and privateWindows are the daemon's two facts.
     */
    async function make(folder, { profile = "standard", clock, state, route = "image", privateWindows = SHIPPED, registers = true } = {}) {
        const Router = require(path.join(folder, "ToolRouter.js"));
        const Executors = require(path.join(folder, "Executors.js"));
        const Audit = require(path.join(folder, "Audit.js"));
        const { SessionRunner, unavailable } = require(path.join(folder, "session-runner.js"));
        let transcript;
        const waiters = [];
        const auditRoot = fs.mkdtempSync(path.join(root, "vision-audit-"));
        const audit = Audit.create({ state: auditRoot, now: () => Date.UTC(2026, 9, 1) });
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {},
                outcome: value => { waiters.splice(0).forEach(resolve => resolve(value)); } } };
        const runner = new SessionRunner(Session, ports, { now: () => 0, set: () => ({}), clear() {} }, () => {});
        const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e),
            context: () => ({ profile, locked: screen.locked(), denied: null }), audit, result: value => ports.brain.outcome(value) });
        Object.assign(ports, router.ports);
        const registered = new Map();
        const facts = { route, privateWindows };
        const reads = hyprctlReads();
        const executors = Executors.register({ register(id, executor) { registered.set(id, executor); router.register(id, executor); } },
            { find: commandFile, environment: ENVIRONMENT, clock,
                desktop: { Dispatch, Launch, request: () => assert.fail("no desktop request"), clock: CLOCK, environment: HYPRLAND, commands: [] },
                vision: { directory, state: state ?? (() => runner.state), route: () => facts.route, privateWindows: () => facts.privateWindows } });
        // Registration follows the session's probe read; polls its log, not a latency.
        for (let wait = 0; registers ? !registered.has("vision") : hyprctlReads() === reads; wait++) {
            assert.ok(wait < 500, "vision registration");
            await pause(10);
        }
        await pause(registers ? 0 : 50);
        function turn() {
            runner.dispatch({ type: "snapshot", locked: false, engine: "chained", configured: true, settings: {} });
            runner.dispatch({ type: "indicator", shown: true });
            runner.dispatch({ type: "talk-down" });
            transcript("final", "fixture user");
        }
        turn();
        function send(tool, args = {}) {
            const answered = new Promise(resolve => waiters.push(resolve));
            const routed = router.route({ kind: "tool-call", id: "model-" + tool, tool, arguments: args },
                { gen: runner.state.turn.gen, op: runner.state.turn.op });
            if (routed.kind !== "proposed") return Promise.resolve({ refused: routed });
            return answered.then(value => {
                assert.equal(value.results.length, 1);
                assert.equal(value.results[0].id, "model-" + tool);
                return { outcome: value.outcome, item: value.results[0].item, image: value.results[0].image };
            });
        }
        // The next turn the user starts.
        function next() {
            runner.dispatch({ type: "brain-done", gen: runner.state.turn.gen, op: runner.state.turn.op });
            runner.dispatch({ type: "talk-up" });
            turn();
        }
        // A direct call with a caller's authority, as the router makes one.
        function direct(id, args = {}, authorize = allow) {
            return new Promise(resolve => registered.get("vision").start(Object.freeze({ id, args }), resolve, authorize));
        }
        function audited() {
            const lines = fs.readFileSync(path.join(auditRoot, "audit/2026-10-01.jsonl"), "utf8").split("\n").filter(Boolean);
            return { text: lines.join("\n"), records: lines.map(JSON.parse) };
        }
        function close() { runner.close(); executors.close(); audit.close(); }
        return { router, runner, registered, facts, send, next, direct, audited, close };
    }
    async function within(folder, options, check) {
        const w = await make(folder, options);
        try { return await check(w); } finally { w.close(); }
    }
    const scene = (layout, clients) => ({ monitors: layout.monitors, outputs: layout.outputs, clients, colors: COLORS });
    const refusal = reason => JSON.stringify({ kind: "refuse", reason });
    // The executor's own deadline, fired once the stand-in holds.
    const onHeld = (name, ms) => ({ set(fn, wanted) {
        assert.equal(wanted, ms);
        held(name).then(fn);
        return name;
    }, clear() {} });
    async function held(name) {
        const marker = path.join(screen.fixture, name + ".held");
        for (let i = 0; i < 1000 && !fs.existsSync(marker); i++) await pause(5);
        assert.ok(fs.existsSync(marker), "stand-in never held: " + name);
        return JSON.parse(fs.readFileSync(marker, "utf8"));
    }
    // Only controls get this bound: a broken copy that never ends a child
    // reaches it in 1 s. Passing cases keep each production deadline.
    const bounded = { set: (fn, ms) => setTimeout(fn, Math.min(ms, 1000)), clear: timer => clearTimeout(timer) };
    const alive = pid => {
        try { process.kill(pid, 0); return true; }
        catch (error) { if (error.code === "ESRCH") return false; throw error; }
    };

    const cases = new Map([
        ["geometry", async folder => {
            const Screen = require(path.join(folder, "Screen.js"));
            for (const [name, transforms, output, [x, y, w, h], [width, height], [wx, wy, ww, wh], mask] of GEOMETRY) {
                for (const transform of transforms) {
                    const reading = { monitors: [monitor(0, "FIX-1", { ...output, transform })],
                        clients: [secret("0xa1", [wx, wy], [ww, wh])] };
                    const plan = Screen.plan({ id: "vision.monitor", args: { monitor: "FIX-1" } }, reading, SHIPPED, Dispatch.onScreen);
                    const label = name + " transform " + transform;
                    assert.equal(plan.kind, "capture", label + ": " + plan.reason);
                    assert.deepEqual([plan.box, plan.image, plan.masks], [{ x, y, w, h }, { width, height }, [mask]], label);
                    assert.deepEqual(plan.grim, ["-s", String(output.scale), "-o", "FIX-1"], label);
                }
            }
        }],
        ["masks", async folder => {
            for (const [name, layout, clients, [tool, args], facts, probes] of MASKS) {
                screen.set(scene(layout, clients));
                await within(folder, {}, async w => {
                    const value = await w.send(tool, args);
                    assert.equal(value.outcome, "completed", name + ": " + value.item.content);
                    assert.deepEqual(value.item.labels, ["screen"], name);
                    assert.ok(value.image !== undefined, name + ": the result carries the image");
                    assert.equal(value.image.type, "image/png", name);
                    assert.deepEqual(value.image.item.labels, ["screen"], name + ": the image carries the screen label");
                    const bytes = picture(value, "release");
                    const record = w.audited().records.at(-1);
                    assert.deepEqual(record.capture, { ...facts, bytes: bytes.length, sha256: sha(bytes) }, name + " audit");
                    const image = decode(bytes);
                    assert.deepEqual([image.width, image.height], [facts.width, facts.height], name);
                    for (const [x, y, rgba] of probes) assert.deepEqual(image.pixel(x, y), rgba, name + " pixel " + x + "," + y);
                    assert.equal(calls("magick").length, facts.masks === 0 ? 0 : 1, name + ": magick paints only a mask");
                    if (facts.masks === 0) assert.equal(sha(bytes), screen.grim(0).sha256, name + ": an image without a mask is grim's");
                    assert.ok(value.item.content.includes(facts.width + " by " + facts.height + " pixels"), name);
                    assert.deepEqual(left(), [], name + ": the call removes its files");
                });
            }
        }],
        ["refusals", async folder => {
            for (const [name, layout, clients, [tool, args], reason] of REFUSALS) {
                screen.set(scene(layout, clients));
                await within(folder, {}, async w => {
                    const value = await w.send(tool, args);
                    assert.deepEqual([value.outcome, value.item.content, value.image === undefined], ["failed", refusal(reason), true], name);
                    assert.equal(calls("grim").length, 0, name + ": no capture");
                });
            }
        }],
        ["commands", async folder => {
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])]),
                { tesseract: { stdout: "FIXTURE SCREEN TEXT\n" } });
            await within(folder, { route: "text" }, async w => {
                const value = await w.send("vision.monitor", { monitor: "FIX-1" });
                assert.equal(value.outcome, "completed", value.item.content);
                assert.equal(value.image, undefined, "the text route carries no image");
                assert.ok(value.item.content.endsWith("this is its OCR text.\nFIXTURE SCREEN TEXT"), value.item.content);
                assert.deepEqual(value.item.labels, ["screen"], "OCR text carries the screen label");
                const ran = screen.calls();
                assert.deepEqual(ran.map(call => call.name), ["grim", "magick", "tesseract"]);
                const [grim, magick, tesseract] = ran;
                const shot = grim.argv.at(-1), painted = magick.argv.at(-1).slice("PNG32:".length);
                assert.equal(path.dirname(shot), directory);
                assert.equal(path.dirname(painted), directory);
                assert.deepEqual(grim.argv, ["-s", "1", "-o", "FIX-1", shot]);
                assert.deepEqual(magick.argv, ["png:" + shot, "+antialias", "-fill", "black", "-draw", "rectangle 20,30 119,79", "PNG32:" + painted]);
                assert.deepEqual(tesseract.argv, [painted, "stdout", ...OCR], "OCR reads the painted file");
                const record = w.audited().records.at(-1);
                assert.equal(tesseract.input, record.capture.sha256, "the audited hash is the painted image's");
                assert.notEqual(tesseract.input, screen.grim(0).sha256, "OCR never reads the unpainted capture");
                for (const call of ran) {
                    assert.deepEqual(call.env, EXPECTED_ENV[call.name], call.name + " environment");
                    assert.equal(call.group, call.pid, call.name + " leads its own process group");
                    assert.equal(call.parent, process.pid, call.name + ": setpriv execs the command itself");
                    assert.equal(call.deathsig, 9, call.name + " dies with its parent");
                }
                assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
                assert.deepEqual(left(), []);
            });
            // Without tesseract a text route refuses rather than sending nothing.
            const saved = process.env.PATH;
            const partial = fs.mkdtempSync(path.join(root, "probe-"));
            for (const name of ["grim", "magick", "hyprctl"]) fs.copyFileSync(path.join(root, "standins", name), path.join(partial, name));
            process.env.PATH = partial + ":" + path.join(root, "tools");
            try {
                screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80])]));
                await within(folder, { route: "text" }, async w => {
                    const value = await w.send("vision.screen");
                    assert.deepEqual([value.outcome, value.item.content], ["failed", refusal("ocr-unavailable")]);
                });
            } finally { process.env.PATH = saved; }
        }],
        ["probe", async folder => {
            const saved = process.env.PATH;
            try {
                // Present commands, then whether vision registers and the tools offered.
                for (const [name, present, offered] of [
                    ["all", STANDINS, ["vision.screen", "vision.monitor", "vision.window", "vision.region", "vision.area"]],
                    ["no slurp", ["grim", "magick", "tesseract"], ["vision.screen", "vision.monitor", "vision.window", "vision.region"]],
                    ["no tesseract", ["grim", "magick"], ["vision.screen", "vision.monitor", "vision.window", "vision.region"]],
                    ["no magick", ["grim", "slurp", "tesseract"], null],
                    ["no grim", ["magick", "slurp", "tesseract"], null]
                ]) {
                    const directoryOf = fs.mkdtempSync(path.join(root, "probe-"));
                    for (const command of [...present, "hyprctl"])
                        fs.copyFileSync(path.join(root, "standins", command), path.join(directoryOf, command));
                    process.env.PATH = directoryOf + ":" + path.join(root, "tools");
                    screen.set(scene(flat, []));
                    await within(folder, { registers: offered !== null }, async w => {
                        assert.equal(w.registered.has("vision"), offered !== null, name);
                        assert.deepEqual(w.router.offer().map(tool => tool.id).filter(id => id.startsWith("vision.")), offered ?? [], name);
                        assert.deepEqual(screen.calls(), [], name + ": the probe runs no command");
                    });
                }
                process.env.PATH = saved;
                // No Hyprland answer, no vision tools: registration waits for the probe.
                screen.set(scene(flat, []));
                fs.writeFileSync(path.join(runtime, "hyprctl.fail"), "");
                await within(folder, { registers: false }, async w => assert.equal(w.registered.has("vision"), false));
            } finally { process.env.PATH = saved; }
        }],
        ["release", async folder => {
            const Policy = require(path.join(folder, "Policy.js"));
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])]));
            await within(folder, {}, async w => {
                const value = await w.send("vision.screen");
                assert.equal(value.outcome, "completed");
                const bytes = picture(value, "release");
                assert.ok(bytes instanceof Uint8Array && bytes.length > 0);
                const audit = w.audited().text;
                for (const leak of [bytes.toString("base64").slice(0, 64), bytes.toString("latin1", 0, 32), bytes.toString("hex").slice(0, 64)])
                    assert.equal(audit.includes(leak), false, "the audit holds no image bytes");
                const remote = { kind: "network", provider: "brain", account: "fixture", origin: "https://brain.example" };
                const local = { kind: "local", provider: "local", account: "" };
                const select = (cloudVision, brain = remote) => Policy.recipients({ conversation: "fixture", profile: "trusted",
                    cloudVision, brain, speech: [local] });
                for (const item of [value.item, value.image.item]) {
                    const asked = Policy.release(item, select("ask"));
                    assert.deepEqual([asked.kind, asked.content, asked.needed], ["ask", "[withheld: screen content]", ["screen"]],
                        "ask holds screen content even in trusted");
                    assert.deepEqual([...Object.values(Policy.release(item, select("never")))].slice(0, 2), ["withhold", "[withheld: screen content]"]);
                    for (const recipients of [select("allow"), select("never", local)]) {
                        const sent = Policy.release(item, recipients);
                        assert.equal(sent.kind, "send");
                        assert.deepEqual(Buffer.from(sent.content), Buffer.from(item.content));
                    }
                }
            });
        }],
        ["locked", async folder => {
            screen.set(scene(flat, [secret("0xa1", [20, 30], [100, 50])]));
            screen.lock();
            await within(folder, {}, async w => {
                const routed = await w.send("vision.screen");
                assert.deepEqual(routed.refused, { kind: "refuse", reason: "session-locked" }, "Policy refuses a locked capture");
            });
            await within(folder, { state: () => RUNNING }, async w => {
                const value = await w.direct("vision.screen");
                assert.deepEqual(value, { outcome: "failed", content: refusal("session-locked") });
                assert.equal(calls("grim").length, 0, "locked before: no capture");
            });
        }],
        ["lock-across", async folder => {
            screen.set(scene(flat, [secret("0xa1", [20, 30], [100, 50])]), { grim: { lock: 0 } });
            await within(folder, {}, async w => {
                const value = await w.send("vision.screen");
                // The router's own authority refused it, which it reports as cancelled.
                assert.deepEqual([value.outcome, value.item.content, value.image === undefined], ["cancelled", refusal("session-locked"), true]);
                assert.equal(calls("grim").length, 1);
                assert.equal(calls("magick").length, 0, "the image never reaches the painter");
                assert.equal(fs.existsSync(screen.grim(0).file), false, "an image taken across a lock is deleted");
                assert.deepEqual(left(), []);
            });
        }],
        ["races", async folder => {
            const start = [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])];
            const moved = [start[0], secret("0xa1", [200, 100], [100, 50])];
            const after = clients => screen.state(flat.monitors, clients);
            // [name, call, states each grim writes, outcome, content, grim runs, pixel probes]
            for (const [name, call, states, outcome, content, runs, probes] of [
                ["moved-once", ["vision.screen", {}], [after(moved)], "completed", null, 2, [[200, 100, BLACK], [299, 149, BLACK], [20, 30, BG]]],
                ["moving", ["vision.screen", {}], [after(moved), after(start)], "failed", refusal("screen-changed"), 2, null],
                ["window-set", ["vision.screen", {}], [after([...start, plain("0xc3", [0, 150], [50, 40])])], "completed", null, 2, [[20, 30, BLACK], [10, 160, [...BLUE, 255]]]],
                ["public-moved", ["vision.screen", {}], [after([plain("0xb2", [160, 50], [100, 80]), start[1]])], "completed", null, 1, null],
                ["target-closed", ["vision.window", { window: "0xb2" }], [after([start[1]])], "failed", refusal("window-absent"), 1, null]
            ]) {
                screen.set(scene(flat, start), { grim: { states } });
                await within(folder, {}, async w => {
                    const value = await w.send(...call);
                    assert.equal(value.outcome, outcome, name + ": " + value.item.content);
                    if (content !== null) assert.equal(value.item.content, content, name);
                    assert.equal(calls("grim").length, runs, name + " captures");
                    for (const [x, y, rgba] of probes ?? []) assert.deepEqual(decode(picture(value, name)).pixel(x, y), rgba, name + " " + x + "," + y);
                    assert.deepEqual(left(), [], name);
                });
            }
        }],
        ["turns", async folder => {
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80])]));
            await within(folder, {}, async w => {
                // Session's own record: a turn with no running action is not the user's call.
                assert.deepEqual(await w.direct("vision.screen"), { outcome: "failed", content: refusal("outside-turn") });
                for (let i = 0; i < 4; i++) assert.equal((await w.send("vision.screen")).outcome, "completed", "capture " + i);
                assert.deepEqual((await w.send("vision.screen")).item.content, refusal("screenshot-limit"));
                assert.equal(calls("grim").length, 4);
                w.next();
                assert.equal((await w.send("vision.screen")).outcome, "completed", "a new turn starts a new count");
            });
            for (const state of [{ turn: { kind: "none" }, action: { kind: "none" } },
                { turn: { kind: "cancelling", gen: 1, op: 5, deadline: 1 }, action: RUNNING.action },
                { turn: RUNNING.turn, action: { ...RUNNING.action, brain: 4 } }])
                await within(folder, { state: () => state }, async w =>
                    assert.deepEqual(await w.direct("vision.screen"), { outcome: "failed", content: refusal("outside-turn") }, JSON.stringify(state)));
            assert.equal(calls("grim").length, 5, "no capture outside a live user turn");
        }],
        ["area", async folder => {
            const clients = [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])];
            for (const [name, slurp, outcome, content] of [
                ["drawn", { stdout: "10,10 200x100\n" }, "completed", null],
                ["cancelled", { code: 1, stderr: "selection cancelled\n" }, "failed", refusal("area-cancelled")],
                ["broken", { code: 1, stderr: "compositor doesn't support wlr-layer-shell-unstable-v1\n" }, "failed",
                    JSON.stringify({ kind: "failed", command: "slurp", code: 1, detail: "compositor doesn't support wlr-layer-shell-unstable-v1" })],
                ["shape", { stdout: "10,10 0x100\n" }, "failed", refusal("area-shape")]
            ]) {
                screen.set(scene(flat, clients), { slurp });
                await within(folder, {}, async w => {
                    const value = await w.send("vision.area");
                    assert.equal(value.outcome, outcome, name + ": " + value.item.content);
                    if (content !== null) assert.equal(value.item.content, content, name);
                    const [picked] = calls("slurp");
                    assert.deepEqual([picked.argv, picked.env], [["-f", "%x,%y %wx%h"], EXPECTED_ENV.slurp], name);
                    if (outcome === "completed") {
                        assert.deepEqual(calls("grim")[0].argv.slice(0, 4), ["-s", "1", "-g", "10,10 200x100"]);
                        assert.deepEqual(w.audited().records.at(-1).capture.box, [10, 10, 200, 100]);
                        assert.deepEqual(decode(picture(value, name)).pixel(10, 20), BLACK);
                    } else assert.equal(calls("grim").length, 0, name);
                });
            }
        }],
        ["failures", async folder => {
            const clients = [plain("0xb2", [150, 40], [100, 80]), secret("0xa1", [20, 30], [100, 50])];
            for (const [name, people, modes, content] of [
                ["grim-exit", clients, { grim: { code: 1, stderr: "failed to create display\n" } },
                    JSON.stringify({ kind: "failed", command: "grim", code: 1, detail: "failed to create display" })],
                ["image-size", clients, { grim: { size: [100, 100] } }, refusal("image-size")],
                ["mask-failed", clients, { grim: { corrupt: true } }, refusal("mask-failed")],
                ["image-bytes", [clients[0]], { grim: { pad: 4 * 1024 * 1024 } }, refusal("image-bytes")]
            ]) {
                screen.set(scene(flat, people), modes);
                await within(folder, {}, async w => {
                    const value = await w.send("vision.screen");
                    assert.deepEqual([value.outcome, value.item.content, value.image === undefined], ["failed", content, true], name);
                    assert.deepEqual(left(), [], name);
                });
            }
            screen.set(scene(flat, clients));
            await within(folder, {}, async w => {
                fs.writeFileSync(path.join(runtime, "hyprctl.fail"), "");
                const value = await w.send("vision.screen");
                assert.deepEqual([value.outcome, value.item.content], ["failed", JSON.stringify({ kind: "failed",
                    reason: "hyprland-read", detail: "Hyprland state could not be read: hyprctl exit=1." })]);
                assert.equal(calls("grim").length, 0);
            });
        }],
        ["stopped", async (folder, clock) => {
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80])]), { grim: { hold: true } });
            await within(folder, { state: () => RUNNING, clock }, async w => {
                const call = Object.freeze({ id: "vision.screen", args: {} });
                const answer = new Promise(resolve => w.registered.get("vision").start(call, resolve, allow));
                const { pid } = await held("grim");
                w.registered.get("vision").cancel(call);
                assert.deepEqual(await answer, { outcome: "failed", content: JSON.stringify({ kind: "stopped", command: "grim", reason: "cancelled" }) });
                assert.equal(alive(pid), false, "cancel ends grim's group");
                assert.deepEqual(left(), []);
            });
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80])]), { grim: { hold: true } });
            await within(folder, { clock: clock ?? onHeld("grim", 5000) }, async w => {
                const value = await w.send("vision.screen");
                assert.equal(value.item.content, JSON.stringify({ kind: "stopped", command: "grim", reason: "timeout" }));
                assert.deepEqual(left(), []);
            });
        }],
        ["lifetime", async folder => {
            screen.set(scene(flat, [plain("0xb2", [150, 40], [100, 80])]));
            fs.mkdirSync(directory, { recursive: true });
            fs.writeFileSync(path.join(directory, "left-by-a-killed-daemon.png"), "PRIVATE");
            const w = await make(folder);
            try {
                assert.equal(fs.existsSync(directory), false, "install removes a killed daemon's files");
                assert.equal((await w.send("vision.screen")).outcome, "completed");
                assert.equal(fs.existsSync(directory), true);
            } finally { w.close(); }
            assert.equal(fs.existsSync(directory), false, "teardown removes the directory");
        }]
    ]);

    // file, control, the text kept, its replacement, the case it reddens and
    // whether its broken copy needs the short bound to end a child.
    const CONTROLS = [
        ["Screen.js", "mask-removed", "if (part === null) continue;", "continue;", "masks"],
        ["Screen.js", "transform-ignored", "const turned = monitor.transform % 2 === 1;", "const turned = false;", "masks"],
        // Omarchy's monitor rule: only transforms 1 and 3 turn, and the size floors.
        ["Screen.js", "flipped-unturned", "const turned = monitor.transform % 2 === 1;",
            "const turned = monitor.transform === 1 || monitor.transform === 3;", "geometry"],
        ["Screen.js", "size-floored", [
            ["w: Math.round((turned ? monitor.height : monitor.width) / monitor.scale)", "w: Math.floor((turned ? monitor.height : monitor.width) / monitor.scale)"],
            ["h: Math.round((turned ? monitor.width : monitor.height) / monitor.scale)", "h: Math.floor((turned ? monitor.width : monitor.height) / monitor.scale)"]],
        null, "geometry"],
        ["Screen.js", "scale-ignored", [
            ["Math.floor((part.x - box.x) * scale)", "Math.floor(part.x - box.x)"],
            ["Math.floor((part.y - box.y) * scale)", "Math.floor(part.y - box.y)"],
            ["Math.ceil((part.x + part.w - box.x) * scale)", "Math.ceil(part.x + part.w - box.x)"],
            ["Math.ceil((part.y + part.h - box.y) * scale)", "Math.ceil(part.y + part.h - box.y)"]], null, "masks"],
        ["Screen.js", "mask-inward", "Math.floor((part.x - box.x) * scale)", "Math.ceil((part.x - box.x) * scale)", "masks"],
        ["Screen.js", "hidden-workspace-skipped", "for (const client of clients.filter(client => isPrivate(client, list))) {",
            "for (const client of clients.filter(client => isPrivate(client, list) && onScreen(client, reading.monitors))) {", "masks"],
        ["Screen.js", "window-shown", 'if (!onScreen(client, monitors)) return refuse("window-hidden");', "", "refusals"],
        ["Screen.js", "private-target", 'if (isPrivate(client, list)) return refuse("private-window");', "", "refusals"],
        ["Screen.js", "region-bounds", "\n                || box.x + box.w > screen.x + screen.w || box.y + box.h > screen.y + screen.h)", ")", "refusals"],
        ["Screen.js", "region-shown", "if (shown.length === 0 || box.x < screen.x", "if (box.x < screen.x", "refusals"],
        ["Screen.js", "window-set-ignored", "key: JSON.stringify({ box, scale, windows, hidden })", "key: JSON.stringify({ box, scale, hidden })", "races"],
        ["Vision.js", "retry-dropped", "if (shot.kind === \"changed\") shot = await shoot(target, authorize, signal, files);", "", "races"],
        ["Vision.js", "move-unchecked", "after.key !== before.key", "false", "races"],
        ["Vision.js", "lock-check-dropped", "const early = halted(authorize);\n        if (early !== null) return { kind: \"failed\", answer: early };", "", "locked"],
        ["Vision.js", "image-kept-across-lock", "if (late !== null) { remove(file); return { kind: \"failed\", answer: late }; }", "", "lock-across"],
        ["Vision.js", "audit-bytes", "masks: plan.masks.length };", "masks: plan.masks.length, image: bytes.toString(\"base64\") };", "masks"],
        ["Vision.js", "ocr-skipped", "const way = route();", "const way = \"image\";", "commands"],
        ["Vision.js", "ocr-unpainted", "run(\"tesseract\", [out,", "run(\"tesseract\", [file,", "commands"],
        ["Vision.js", "outside-turn", "if (turn === null) return refuse(\"outside-turn\");", "if (turn === null) taken = { turn: null, count: 0 };", "turns"],
        ["Vision.js", "turn-bound", "if (taken.count >= TURN_LIMIT)", "if (taken.count > TURN_LIMIT)", "turns"],
        ["Vision.js", "files-kept", "try { for (const file of files) remove(file); }", "try { void files; }", "masks"],
        ["Vision.js", "size-unchecked", "if (size === null || size.width !== plan.image.width || size.height !== plan.image.height) return refuse(\"image-size\");",
            "if (size === null) return refuse(\"image-size\");", "failures"],
        ["Vision.js", "paint-unchecked", "if (painted.kind !== \"exited\" || painted.code !== 0) return refuse(\"mask-failed\");", "", "failures"],
        ["Vision.js", "image-unbounded", "if (stat.size > IMAGE_BYTES) return null;", "", "failures"],
        ["Vision.js", "temporary-path", "{ MAGICK_TEMPORARY_PATH: directory }", "{}", "commands"],
        ["Vision.js", "magick-optional", "if (!commands.has(\"grim\") || !commands.has(\"magick\"))", "if (!commands.has(\"grim\"))", "probe"],
        ["Vision.js", "probe-first", "if (reached && lifetime === \"open\")", "if (lifetime === \"open\")", "probe"],
        ["Vision.js", "area-cancel", "=== CANCELLED)", "=== \"\")", "area"],
        ["Vision.js", "cancel", "cancel: call => { running.get(call)?.abort(); }", "cancel: call => { void call; }", "stopped", true],
        ["Vision.js", "deadline", "grim: 5000,", "grim: 6000,", "stopped"],
        ["Vision.js", "stale-sweep", "fs.rmSync(directory, { recursive: true, force: true });\n    const running", "const running", "lifetime"],
        ["Tools.js", "label-dropped", "\"vision.screen\": { sentence: \"Read the screen\", effect: \"read\", executor: \"vision\", command: \"grim\", schema: {}, source: \"screen\" }",
            "\"vision.screen\": { sentence: \"Read the screen\", effect: \"read\", executor: \"vision\", command: \"grim\", schema: {} }", "release"],
        ["ToolRouter.js", "image-dropped", "results: [{ id: value.request, item, ...(image === undefined ? {}", "results: [{ id: value.request, item, ...(true ? {}", "masks"]
    ];
    for (const [name, check] of cases) { await check(backend); console.log("case=" + name + " passed"); }
    for (const [source, name, needle, replacement, row, bound] of CONTROLS) {
        await mutant(file(source), name, needle, replacement, (module, folder) => cases.get(row)(folder, bound ? bounded : undefined), "Executors.js");
        console.log("control=" + name + " detected");
    }
    console.log("test-jarvis-vision: ok cases=" + cases.size + " controls=" + CONTROLS.length);
}

world(() => main().catch(error => { console.error(error); process.exitCode = 1; }), standins => {
    Desk.standins(standins);
    for (const name of STANDINS)
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/vision-tool.py"), path.join(standins, name));
    for (const name of STANDINS) fs.chmodSync(path.join(standins, name), 0o755);
});
