import QtQuick
import QtTest
import qs.Core
import Quickshell.Io
import Qt.labs.folderlistmodel

Item {
    id: root

    Component {
        id: recordsComponent
        TuiRecords {
            recordDir: "/unit/tui"
            coreBin: "/unit/bin"
        }
    }

    TestCase {
        name: "tui-records"

        property var records: null
        property var model: null
        property var events: []
        readonly property string key: "acme.tui/hello"
        readonly property string run: "1-1"
        readonly property string runningPath: "/unit/tui/acme.tui@hello@1-1.running.json"
        readonly property string endedPath: "/unit/tui/acme.tui@hello@1-1.ended.json"

        function record(state, code) {
            return {
                key: key,
                run: run,
                state: state,
                code: code,
                startedAt: "2026-09-29T07:00:00.000Z",
                endedAt: state === "ended" ? "2026-09-29T07:00:01.000Z" : null,
                window: { appId: "org.vgs.tui", title: "VGS · Hello" }
            };
        }

        function init() {
            ProcessRegistry.clear();
            FolderListRegistry.clear();
            records = createTemporaryObject(recordsComponent, root);
            verify(records !== null, "the record owner builds");
            compare(FolderListRegistry.models.length, 1);
            model = FolderListRegistry.models[0];
            finishReap();
            events = [];
        }

        function finishReap() {
            const reaps = ProcessRegistry.runningWithVerb("reap");
            if (reaps.length === 1) reaps[0].finish(0, 0, "", "");
        }

        function waitProcesses() {
            return ProcessRegistry.runningWithVerb("wait");
        }

        function listRunning() {
            model.setFiles([runningPath], "reset");
            verify(Object.prototype.hasOwnProperty.call(records.readers, runningPath), "the running record gets a reader");
            records.readers[runningPath].finishRead(JSON.stringify(record("running", null)));
        }

        function addDone() {
            records.addWaiter("core", run, result => events.push(result));
            records.deliverKnown(run);
        }

        function finishWait(code) {
            const waits = waitProcesses();
            compare(waits.length, 1);
            waits[0].finish(0, 0, JSON.stringify(record("ended", code)) + "\n", "");
        }

        function test_wait_covers_a_dropped_folder_change() {
            compare(waitProcesses().length, 0);
            addDone();
            listRunning();
            compare(waitProcesses().length, 1);
            model.setFiles([runningPath, endedPath], "drop");
            finishWait(7);
            compare(JSON.stringify(events), JSON.stringify([{ code: 7, reason: null }]));
            compare(records.runs.keys[key].running, null);
            compare(records.record().waits, []);
            wait(0);
            compare(JSON.stringify(events), JSON.stringify([{ code: 7, reason: null }]));
        }

        function test_listing_end_before_wait_calls_done_once() {
            addDone();
            listRunning();
            model.setFiles([runningPath, endedPath], "insert");
            verify(Object.prototype.hasOwnProperty.call(records.readers, endedPath), "the ended record gets a reader");
            records.readers[endedPath].finishRead(JSON.stringify(record("ended", 3)));
            compare(JSON.stringify(events), JSON.stringify([{ code: 3, reason: null }]));
            finishWait(3);
            compare(JSON.stringify(events), JSON.stringify([{ code: 3, reason: null }]));
            compare(records.record().waits, []);
        }

        function test_no_wait_before_or_after_a_run() {
            compare(waitProcesses().length, 0);
            listRunning();
            compare(waitProcesses().length, 1);
            finishWait(0);
            compare(waitProcesses().length, 0);
            compare(records.record().waits, []);
        }

        function test_dead_run_answers_vanished() {
            addDone();
            listRunning();
            finishWait(null);
            compare(JSON.stringify(events), JSON.stringify([{ code: null, reason: "vanished" }]));
            compare(records.runs.keys[key].running, null);
        }

        function test_launched_run_starts_wait_without_a_listing() {
            addDone();
            records.launched(key, run);
            compare(waitProcesses().length, 1);
            finishWait(9);
            compare(JSON.stringify(events), JSON.stringify([{ code: 9, reason: null }]));
            compare(records.runs.keys[key].ended.run, run);
        }

        // The listing keeps the first run's running record through a second
        // run of the key: the second run's wait record must not bring the
        // first run back to running, nor start another wait for it.
        function test_a_stale_listing_across_two_runs_keeps_the_first_ended() {
            addDone();
            listRunning();
            model.setFiles([runningPath, endedPath], "drop");
            finishWait(7);
            const second = Object.assign(record("ended", 4), { run: "2-1", startedAt: "2026-09-29T07:00:02.000Z", endedAt: "2026-09-29T07:00:03.000Z" });
            const secondEvents = [];
            records.addWaiter("core", "2-1", result => secondEvents.push(result));
            records.launched(key, "2-1");
            const waits = waitProcesses();
            compare(waits.length, 1);
            waits[0].finish(0, 0, JSON.stringify(second) + "\n", "");
            compare(JSON.stringify(secondEvents), JSON.stringify([{ code: 4, reason: null }]));
            compare(records.runs.keys[key].running, null);
            compare(records.runs.keys[key].ended.run, "2-1");
            compare(waitProcesses().length, 0);
        }

        function runPath(id, state) {
            return "/unit/tui/acme.tui@hello@" + id + "." + state + ".json";
        }

        function runRecord(id, state, code, second) {
            return Object.assign(record(state, code), {
                run: id,
                startedAt: "2026-09-29T07:00:0" + second + ".000Z",
                endedAt: state === "ended" ? "2026-09-29T07:00:0" + (second + 1) + ".000Z" : null
            });
        }

        function listAndRead(files, signalName, path, text) {
            model.setFiles(files, signalName);
            verify(Object.prototype.hasOwnProperty.call(records.readers, path), "the record gets a reader: " + path);
            records.readers[path].finishRead(text);
        }

        function waitOf(id) {
            const waits = waitProcesses().filter(process => process.command[5] === id);
            compare(waits.length, 1, "one wait for run " + id);
            return waits[0];
        }

        // Back to back: run 1-1's ended record is read from the listing, run
        // 2-1 of the same key starts, and 2-1's presenter removes 1-1's
        // records before 1-1's wait reads them, so that wait ends with the
        // gone code, 3. The core already delivered 1-1's done and 2-1's wait
        // stays live. Whether the gone end logs a line is
        // PluginLogic.tuiWaitOutcome's decision, pinned with its controls by
        // scripts/test-tui-logic.js; this harness does not capture the log,
        // so no edit to that decision reddens this test. It holds that the
        // gone end changes no run, delivers no second done, starts no new
        // wait, and leaves the later run's wait to deliver its own done.
        function test_a_gone_wait_of_an_ended_run_leaves_the_next_run_alone() {
            const firstEvents = [];
            const secondEvents = [];
            records.addWaiter("core", "1-1", result => firstEvents.push(result));
            records.launched(key, "1-1");
            const firstWait = waitOf("1-1");
            listAndRead([runPath("1-1", "running")], "reset", runPath("1-1", "running"), JSON.stringify(runRecord("1-1", "running", null, 0)));
            listAndRead([runPath("1-1", "running"), runPath("1-1", "ended")], "insert", runPath("1-1", "ended"), JSON.stringify(runRecord("1-1", "ended", 0, 0)));
            compare(JSON.stringify(firstEvents), JSON.stringify([{ code: 0, reason: null }]));
            verify(firstWait.running, "the first run's wait still runs after the listing ended the run");

            records.addWaiter("core", "2-1", result => secondEvents.push(result));
            records.launched(key, "2-1");
            const secondWait = waitOf("2-1");
            listAndRead([runPath("1-1", "ended"), runPath("2-1", "running")], "reset", runPath("2-1", "running"), JSON.stringify(runRecord("2-1", "running", null, 2)));
            model.setFiles([runPath("2-1", "running")], "remove");
            compare(records.runs.runs["1-1"], undefined);
            compare(records.record().waits, [key + "|1-1", key + "|2-1"]);

            firstWait.finish(3, 0, "", "vgsh-tui: refused: wait=acme.tui/hello run=1-1 reason=gone\n");
            compare(JSON.stringify(firstEvents), JSON.stringify([{ code: 0, reason: null }]));
            compare(records.runs.keys[key].running.run, "2-1");
            compare(records.record().waits, [key + "|2-1"]);
            verify(secondWait.running, "the later run's wait is still live");
            compare(JSON.stringify(secondEvents), JSON.stringify([]));

            secondWait.finish(0, 0, JSON.stringify(runRecord("2-1", "ended", 4, 2)) + "\n", "");
            compare(JSON.stringify(secondEvents), JSON.stringify([{ code: 4, reason: null }]));
            compare(JSON.stringify(firstEvents), JSON.stringify([{ code: 0, reason: null }]));
            compare(records.runs.keys[key].running, null);
            compare(records.record().waits, []);
            compare(waitProcesses().length, 0);
        }
    }
}
