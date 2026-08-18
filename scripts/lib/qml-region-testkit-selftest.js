// The self-test for scripts/lib/qml-region-testkit.js — the machinery every other
// region-guard check is built on. It gets its own checks because it is not a
// passive helper: it decides which processes on this box belong to a fixture and
// SIGKILLs them, and it decides what environment a fixture may see. Both had
// defects that no other check could show, because the reaper's behaviour is only
// observable when some OTHER check is already failing.
//
// The bound itself is scripts/lib/qml-region-selftest.js and the plumbing around
// it is scripts/lib/qml-region-wiring-selftest.js; each is its own manifest row.

"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;
const { cmdlineOf, fixtureEnv, reapGuardChildren, withGuardedSuite, pidRunning, waitFor } =
    require("./qml-region-testkit.js");

// A process shaped exactly like a guard child — a script under `dir`, carrying
// the marker — without needing the guard to make one. It sleeps rather than
// spins: what is under test is the reaper's aim, not anything's CPU.
function plantMarkedChild(dir, name) {
    const script = path.join(dir, name);
    fs.writeFileSync(script, "setTimeout(function () {}, 60000);\n");
    const child = spawn(process.execPath, [script, CHILD_ARGV_MARKER], { stdio: "ignore" });
    // spawn returns before exec, so the kernel's command line is not the one the
    // reaper matches on yet. Waiting for it is the difference between testing the
    // reaper's aim and testing this race.
    const ready = waitFor(() => {
        const argv = cmdlineOf(child.pid);
        return argv && argv.includes(script) && argv.includes(CHILD_ARGV_MARKER);
    }, 10000);
    assert.ok(ready, `the planted child never showed ${script} in its command line`);
    return { child, script };
}

module.exports = function regionGuardTestkitSelfTest() {
    // --- no fixture is steerable by the environment it runs in ---
    //
    // Every bound this guard has is an env override, so an ambient one silently
    // re-tunes checks that never asked for it. Measured: with
    // VGS_REGION_CHILD_DEADLINE_MS=300 exported, the hang checks died of the
    // CHILD's bound rather than the supervisor's kill and still passed, and
    // VGS_REGION_ARM_CONFIRM_MS=1 broke the suite outright. The fixture env strips
    // the whole VGS_REGION_ prefix rather than pinning today's three knobs, so
    // this holds for the next bound anyone adds — which is what is checked here.
    {
        process.env.VGS_REGION_NOT_A_REAL_KNOB = "leaked";
        try {
            assert.equal(fixtureEnv().VGS_REGION_NOT_A_REAL_KNOB, undefined,
                "an ambient VGS_REGION_* must not reach a fixture, whatever it is named");
            assert.equal(fixtureEnv({ VGS_REGION_NOT_A_REAL_KNOB: "asked" })
                .VGS_REGION_NOT_A_REAL_KNOB, "asked",
                "but what the fixture asks for must arrive");
            assert.equal(fixtureEnv().PATH, process.env.PATH,
                "and everything else must survive, or the fixture cannot find node");
        } finally {
            delete process.env.VGS_REGION_NOT_A_REAL_KNOB;
        }

        withGuardedSuite({
            prefix: "vgs-region-env-",
            body: () => [
                "guardChild();",
                "console.log('knobs ' + JSON.stringify(",
                "    Object.keys(process.env).filter(k => k.startsWith('VGS_REGION_')).sort()));"
            ]
        }, ({ run, stdout, stderr }) => {
            assert.equal(run.status, 0,
                `the env probe must complete; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(stdout.includes("knobs []"),
                "a fixture that pins nothing must see nothing, so a knob exported around this " +
                `run cannot steer it; the child reported ${JSON.stringify(stdout)}`);
        });
    }

    // --- the reaper takes down this fixture's children, and nothing else ---
    //
    // Attribution is the fixture's mkdtemp DIRECTORY, not one filename: a body
    // plants other scripts too (the descendant probe writes its own inner.js), and
    // a guard child of THAT is the exact shape the reaper exists for. Matching on
    // a directory is also what makes the reaper safe to run at all — a directory
    // belongs to one fixture, so no pid is ever signalled on the strength of a
    // number that may already have been recycled into someone else's run.
    {
        const mine = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-mine-"));
        const theirs = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-theirs-"));
        // Named for the descendant probe's script, not suite.js, so this fails if
        // attribution ever narrows back to a single filename.
        const ours = plantMarkedChild(mine, "inner.js");
        const stranger = plantMarkedChild(theirs, "inner.js");
        try {
            assert.ok(pidRunning(ours.child.pid) && pidRunning(stranger.child.pid),
                "both fixtures must be running, or this proves nothing about which one is hit");

            // Which pids it SELECTS, recorded rather than inferred from who died:
            // the answer is then exact, and says as much about the stranger it left
            // alone as about the child it took.
            const targeted = [];
            const said = [];
            reapGuardChildren(mine, "reaper check",
                { kill: pid => targeted.push(pid), warn: text => said.push(text) });
            assert.deepEqual(targeted, [ours.child.pid],
                "the sweep must select this fixture's child whatever its script is named, and " +
                "no one else's — concurrent runs are normal here, so killing a stranger surfaces " +
                `as an unattributable red in an innocent run; it selected ${JSON.stringify(targeted)}`);
            assert.deepEqual(said, [],
                "a clean sweep says nothing; it said " + JSON.stringify(said.join("")));

            // And once for real, through the default kill.
            reapGuardChildren(mine, "reaper check");
            assert.ok(waitFor(() => !pidRunning(ours.child.pid), 5000),
                "the selected child must actually be gone afterwards");
            assert.ok(pidRunning(stranger.child.pid),
                "and the stranger must still be running");
        } finally {
            for (const planted of [ours, stranger])
                try { process.kill(planted.child.pid, "SIGKILL"); } catch { /* already gone */ }
            fs.rmSync(mine, { recursive: true, force: true });
            fs.rmSync(theirs, { recursive: true, force: true });
        }
    }

    // --- a sweep that could not look says so, and still lets cleanup run ---
    //
    // Both paths run in a finally. An unlistable /proc that threw would replace
    // the real assertion failure with an unrelated errno AND skip the fs.rmSync
    // under it; an entry it could not read, counted as a clean skip, would make a
    // stray it failed to attribute indistinguishable from no stray at all. Neither
    // can be provoked on a healthy box, which is why the seam exists.
    {
        const said = [];
        const denied = new Error("EACCES: permission denied, scandir '/proc'");
        denied.code = "EACCES";
        assert.doesNotThrow(
            () => reapGuardChildren("/tmp/whatever", "unlistable", {
                list: () => { throw denied; },
                warn: text => said.push(text)
            }),
            "an unlistable /proc must not throw out of a finally");
        assert.ok(said.join("").includes("could not list /proc") && said.join("").includes("EACCES"),
            "and must name what stopped it; it said " + JSON.stringify(said.join("")));

        const unreadable = [];
        const killed = [];
        reapGuardChildren("/tmp/whatever", "unreadable", {
            list: () => ["1", "2", "3", "self", "cpuinfo"],
            read: pid => (pid === 2 ? null : []),
            kill: pid => killed.push(pid),
            warn: text => unreadable.push(text)
        });
        assert.deepEqual(killed, [],
            "nothing matched, so nothing may be signalled");
        assert.ok(unreadable.join("").includes("1 /proc entries were unreadable"),
            "an entry that could not be read must be counted and reported, never folded in with " +
            "one that was read and did not match; it said " + JSON.stringify(unreadable.join("")));
    }

    // --- cmdlineOf answers three ways, never two ---
    {
        // Matched on the basename: /proc holds the command line as TYPED, which is
        // relative whenever the runner was invoked that way, while process.argv[1]
        // is always resolved.
        const own = cmdlineOf(process.pid);
        assert.ok(own && own.some(arg => arg.endsWith(path.basename(__filename))),
            "a readable process answers with its argv; it answered " + JSON.stringify(own));
        // No such pid is a READABLE answer: there is no process. Folding it in with
        // "could not look" made the reaper warn about every child that had exited
        // exactly as intended.
        assert.deepEqual(cmdlineOf(0x7ffffffe), [],
            "a pid that does not exist answers empty, not null");
    }
};

if (require.main === module) {
    module.exports();
    console.log("qml-region testkit selftest: all checks passed");
}
