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
    }
}
