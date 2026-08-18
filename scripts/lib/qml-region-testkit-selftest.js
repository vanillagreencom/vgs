// The self-test for scripts/lib/qml-region-testkit.js — the machinery every other
// region-guard check is built on. It gets its own checks because it is not a
// passive helper: it decides which processes on this box belong to a fixture and
// SIGKILLs them, and it decides what environment a fixture may see. Both had
// defects that no other check could show, because the reaper's behaviour is only
// observable when some OTHER check is already failing.
//
// It also owns the fixture-environment checks: keeping a fixture out of reach of
// the environment it runs in is this module's job, not the guard's.
//
// Its entry point is this file, run directly. The map of the subsystem — which
// files exist and which are manifest rows — is in scripts/lib/qml-region.js.

"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;
const { cmdlineOf, fixtureEnv, reapGuardChildren, reapUntilQuiet, withGuardedSuite, pidRunning,
    waitFor } = require("./qml-region-testkit.js");

// A process shaped like a guard child — a script under `dir`, carrying the marker
// unless `marked` is false — without needing the guard to make one. It sleeps
// rather than spins: what is under test is the reaper's aim, not anything's CPU.
function plantMarkedChild(dir, name, marked) {
    const script = path.join(dir, name);
    fs.writeFileSync(script, "setTimeout(function () {}, 60000);\n");
    const spawnArgv = marked === false ? [script] : [script, CHILD_ARGV_MARKER];
    const child = spawn(process.execPath, spawnArgv, { stdio: "ignore" });
    // spawn returns before exec, so the kernel's command line is not the one the
    // reaper matches on yet. Waiting for it is the difference between testing the
    // reaper's aim and testing this race.
    const ready = waitFor(() => {
        const seen = cmdlineOf(child.pid);
        return seen && seen.includes(script) &&
            (marked === false || seen.includes(CHILD_ARGV_MARKER));
    }, 10000);
    if (!ready) {
        // Take it down before throwing. A readiness timeout on a loaded box is the
        // realistic trigger, and this file's whole premise is that a self-test for
        // an orphan does not leave one behind — including from its own scaffolding.
        try { process.kill(child.pid, "SIGKILL"); } catch { /* already gone */ }
        assert.fail(`the planted child never showed ${script} in its command line`);
    }
    return { child, script };
}

function regionGuardTestkitSelfTest() {
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
    // a guard child of THAT is the exact shape the reaper exists for. It is also
    // what makes the reaper safe to run at all — a directory belongs to one
    // fixture, so no pid is ever signalled on the strength of a number that may
    // already have been recycled into someone else's run.
    //
    // Four planted processes, because the match rule has three ways to be wrong:
    // narrowing to one filename, dropping the marker term, and testing a lexical
    // PREFIX rather than a path boundary. Everything is created inside the try, so
    // a readiness failure cannot leak a process or a directory.
    {
        let mine;
        let theirs;
        let sibling;
        const planted = [];
        try {
            mine = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-mine-"));
            theirs = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-theirs-"));
            // A NAME-EXTENSION of `mine`, which mkdtemp can never produce (its
            // suffix is fixed width) but a hand-built fixture path could.
            // startsWith(dir) matched it; a path boundary does not.
            sibling = mine + "-extended";
            fs.mkdirSync(sibling);

            // Named for the descendant probe's script, not suite.js, so this fails
            // if attribution ever narrows back to a single filename.
            const ours = plantMarkedChild(mine, "inner.js");
            planted.push(ours);
            const stranger = plantMarkedChild(theirs, "inner.js");
            planted.push(stranger);
            const neighbour = plantMarkedChild(sibling, "inner.js");
            planted.push(neighbour);
            // Under the swept directory but NOT a guard child. Without the marker
            // term in the rule the sweep would also SIGKILL a fixture's supervisor
            // and any helper a body plants beside its suite.
            const unmarked = plantMarkedChild(mine, "helper.js", false);
            planted.push(unmarked);

            for (const one of planted)
                assert.ok(pidRunning(one.child.pid),
                    `${one.script} must be running, or this proves nothing about which is hit`);

            // Which pids it SELECTS, recorded rather than inferred from who died:
            // the answer is then exact, and says as much about the three it left
            // alone as about the one it took.
            const targeted = [];
            reapGuardChildren(mine, "reaper check", { kill: pid => targeted.push(pid) });
            assert.deepEqual(targeted, [ours.child.pid],
                "the sweep must select this fixture's marked child whatever its script is named " +
                "— and NOT another fixture's, NOT one under a directory whose name merely " +
                "extends this one's, and NOT an unmarked process under this one; it selected " +
                JSON.stringify(targeted));

            // Silence goes through the seam, not the real /proc: a host with
            // hidepid or ProtectProc has unreadable entries this reaper is right to
            // report, and asserting against them would make an unrelated check red.
            const said = [];
            reapGuardChildren(mine, "reaper check",
                { list: () => ["1", "2"], read: () => [], kill: () => {}, warn: t => said.push(t) });
            assert.deepEqual(said, [],
                "a sweep that read every entry says nothing; it said " +
                JSON.stringify(said.join("")));

            // And once for real, through the default kill.
            reapUntilQuiet(mine, "reaper check");
            assert.ok(waitFor(() => !pidRunning(ours.child.pid), 5000),
                "the selected child must actually be gone afterwards");
            for (const spared of [stranger, neighbour, unmarked])
                assert.ok(pidRunning(spared.child.pid),
                    `${spared.script} must still be running after the sweep`);
        } finally {
            for (const one of planted)
                try { process.kill(one.child.pid, "SIGKILL"); } catch { /* already gone */ }
            for (const dir of [mine, theirs, sibling])
                if (dir)
                    fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    // --- the sweep converges instead of racing a chain that is still spawning ---
    //
    // One pass was not enough: a regressed idempotence flag re-execs at every
    // level, and the single pass in withGuardedSuite's finally raced it — one run
    // cleared all 260 processes, another left ~130 alive that drained a minute
    // later on their own. The seam is what makes "keeps going until a sweep finds
    // nothing" checkable without building a real fork bomb to sweep.
    {
        let remaining = 3;
        const sweeps = [];
        reapUntilQuiet("/tmp/whatever", "converging", {
            list: () => (remaining > 0 ? ["101"] : []),
            read: () => ["/tmp/whatever/suite.js", CHILD_ARGV_MARKER],
            kill: pid => { sweeps.push(pid); remaining -= 1; },
            warn: () => {}
        });
        assert.deepEqual(sweeps, [101, 101, 101],
            "the sweep must keep going while it is still finding children, and stop on the pass " +
            `that finds none; it swept ${JSON.stringify(sweeps)}`);

        // And it must give up rather than loop forever against something that
        // never stops appearing.
        const gaveUp = [];
        reapUntilQuiet("/tmp/whatever", "endless", {
            deadlineMs: 200,
            list: () => ["101"],
            read: () => ["/tmp/whatever/suite.js", CHILD_ARGV_MARKER],
            kill: () => {},
            warn: text => gaveUp.push(text)
        });
        assert.ok(gaveUp.join("").includes("still appearing"),
            "a chain that never stops must end the sweep with a report, not a hang; it said " +
            JSON.stringify(gaveUp.join("")));

        // A /proc that cannot be LISTED is the other way a pass finds nothing, and
        // the loop has to tell it apart from a clean sweep. It returned undefined
        // here, which is not 0, so the loop re-listed a /proc that would never list
        // — measured at 12 repeats against a 500ms budget, ~160 against the real
        // one, ending with "still appearing", which is not what happened. The
        // existing unlistable check calls reapGuardChildren directly and so could
        // not see this; the fixtures call reapUntilQuiet.
        //
        // The budget is WIDE and the assertion is tight, which is the way round
        // that costs nothing: a correct sweep returns in ~0ms and never touches the
        // budget, while the regression spins the whole of it. At 500ms only 100ms
        // separated a pass from the failure it detects, and the one thing that
        // could close that gap is a scheduling stall — which would redden CI
        // blaming the reaper for something it did not do, the exact wrong-cause
        // this file keeps arguing against. 5000ms leaves ~4.6s of daylight on a
        // 2 vCPU tier under contention. The warn count beside it reads no clock at
        // all and is the real discriminator: a regression turns 1 into ~100.
        const blind = [];
        const denied = new Error("EACCES: permission denied, scandir '/proc'");
        denied.code = "EACCES";
        const started = Date.now();
        reapUntilQuiet("/tmp/whatever", "unlistable", {
            deadlineMs: 5000,
            list: () => { throw denied; },
            warn: text => blind.push(text)
        });
        assert.ok(Date.now() - started < 400,
            "a sweep that cannot look must return at once, not spin out its 5000ms budget");
        assert.equal(blind.length, 1,
            "and must say so exactly once; it said " + JSON.stringify(blind.join("")));
        assert.ok(blind[0].includes("could not list /proc"),
            "naming the cause it observed; it said " + JSON.stringify(blind[0]));
        assert.ok(!blind.join("").includes("still appearing"),
            "and never the one it did not — nothing was appearing, /proc could not be read");

        // The loop condition above is what makes that true, but the RETURN
        // CONTRACT is what lets any caller tell the two zeroes apart, so it is
        // pinned on its own rather than only through the loop that reads it.
        assert.equal(reapGuardChildren("/tmp/whatever", "clean", {
            list: () => ["1"], read: () => [], kill: () => {}, warn: () => {}
        }), 0, "a sweep that looked and found nothing answers 0");
        assert.equal(reapGuardChildren("/tmp/whatever", "unlistable", {
            list: () => { throw denied; }, warn: () => {}
        }), null, "and one that could not look answers null — never undefined, which is neither");
        assert.equal(reapGuardChildren("/tmp/whatever", "one", {
            list: () => ["7"],
            read: () => ["/tmp/whatever/suite.js", CHILD_ARGV_MARKER],
            kill: () => {}, warn: () => {}
        }), 1, "and one that took something answers how many");
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

    console.log("qml-region testkit selftest: all checks passed");
}

// A SCRIPT, not a module: nothing in the repo requires this file, so there is no
// export and no `require.main` guard to flip. It is a manifest row and a CI line,
// and that row pipes the completion line through grep — so a run that asserted
// nothing prints nothing and the row goes red. The line is printed by the LAST
// statement INSIDE the function for that reason: printed from out here it would
// still appear after someone deleted the call, which is the vacuous pass the
// grep exists to catch.
regionGuardTestkitSelfTest();
