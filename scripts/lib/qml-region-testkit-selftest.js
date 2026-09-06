// Test fixture environment isolation and process cleanup.
// Cleanup failure paths need direct tests because they usually run after another test fails.

"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;
const { cmdlineOf, fixtureEnv, reapGuardChildren, reapUntilQuiet, withGuardedSuite, pidRunning,
    waitFor } = require("./qml-region-testkit.js");

// A sleeping process with a fixture path and optional guard marker tests cleanup selection without spinning.
function plantMarkedChild(dir, name, marked) {
    const script = path.join(dir, name);
    fs.writeFileSync(script, "setTimeout(function () {}, 60000);\n");
    const spawnArgv = marked === false ? [script] : [script, CHILD_ARGV_MARKER];
    const child = spawn(process.execPath, spawnArgv, { stdio: "ignore" });
    // spawn returns before exec. Wait for the command line that cleanup uses to identify the process.
    const ready = waitFor(() => {
        const seen = cmdlineOf(child.pid);
        return seen && seen.includes(script) &&
            (marked === false || seen.includes(CHILD_ARGV_MARKER));
    }, 10000);
    if (!ready) {
        // Terminate the fixture before throwing on readiness failure so the test cannot strand its own helper.
        try { process.kill(child.pid, "SIGKILL"); } catch { /* already gone */ }
        assert.fail(`the planted child never showed ${script} in its command line`);
    }
    return { child, script };
}

const test = require("node:test");

    // Remove ambient VGS_REGION_ overrides so the caller cannot retune fixture deadlines.
    // Test the prefix rule with an unknown name as well as declared settings.
test("fixtureEnv strips ambient VGS_REGION_ overrides and applies the declared knobs", () => {
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
});

    // Test cleanup against another script in the fixture directory, an unmarked process,
    // and a sibling whose path has the same prefix. Setup belongs inside cleanup protection.
test("cleanup reaps only marked children of the fixture directory, not siblings or unmarked processes", () => {
        let mine;
        let theirs;
        let sibling;
        const planted = [];
        try {
            mine = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-mine-"));
            theirs = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-reap-theirs-"));
            // A sibling name extension tests the path boundary that startsWith(dir) alone cannot enforce.
            sibling = mine + "-extended";
            fs.mkdirSync(sibling);

            // A different script basename ensures cleanup covers descendants as well as suite.js.
            const ours = plantMarkedChild(mine, "inner.js");
            planted.push(ours);
            const stranger = plantMarkedChild(theirs, "inner.js");
            planted.push(stranger);
            const neighbour = plantMarkedChild(sibling, "inner.js");
            planted.push(neighbour);
            // An unmarked process under the fixture directory must remain untouched.
            const unmarked = plantMarkedChild(mine, "helper.js", false);
            planted.push(unmarked);

            for (const one of planted)
                assert.ok(pidRunning(one.child.pid),
                    `${one.script} must be running, or this proves nothing about which is hit`);

            // Record selected PIDs directly so exclusions are checked as well as termination.
            const targeted = [];
            reapGuardChildren(mine, "reaper check", { kill: pid => targeted.push(pid) });
            assert.deepEqual(targeted, [ours.child.pid],
                "the sweep must select this fixture's marked child whatever its script is named " +
                "— and NOT another fixture's, NOT one under a directory whose name merely " +
                "extends this one's, and NOT an unmarked process under this one; it selected " +
                JSON.stringify(targeted));

            // Use the injected reader for silence checks; host /proc permissions can legitimately produce warnings.
            const said = [];
            reapGuardChildren(mine, "reaper check",
                { list: () => ["1", "2"], read: () => [], kill: () => {}, warn: t => said.push(t) });
            assert.deepEqual(said, [],
                "a sweep that read every entry says nothing; it said " +
                JSON.stringify(said.join("")));

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
});

    // Repeat the sweep until no child matches. Injected process listings test concurrent spawning
    // without constructing an uncontrolled process chain.
test("the sweep repeats until no child matches", () => {
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

        // An unlistable /proc must stop the sweep instead of looking like more children.
        // The warning count checks repeated attempts without depending on scheduling.
        // The broad time budget leaves room for contention while still detecting a retry loop.
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

        // The return contract must distinguish a clean empty sweep from an unreadable process table.
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
});

    // Cleanup runs in finally. Reading failures must report their cause without replacing
    // the original assertion or preventing directory removal.
test("a reading failure during cleanup names its cause without hiding the original assertion", () => {
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
});

test("cmdlineOf answers a live process argv and an absent pid empty", () => {
        // The kernel stores the invoked command line, which can use a relative script path.
        const own = cmdlineOf(process.pid);
        assert.ok(own && own.some(arg => arg.endsWith(path.basename(__filename))),
            "a readable process answers with its argv; it answered " + JSON.stringify(own));
        // ENOENT means the process is absent; it does not mean its command line was unreadable.
        assert.deepEqual(cmdlineOf(0x7ffffffe), [],
            "a pid that does not exist answers empty, not null");
});
