import QtQuick
import QtTest
import qs.Commons

// WatchedFile against the stand-in FileView, whose operations the test
// finishes by hand: a change or a read() during a read drops that read's
// result and reads again, a failed read included; a change while no read
// is in flight is reported and starts nothing; the watching view is never
// read or reloaded and the reading view watches nothing; and a read or a
// write asked from a result handler still reaches the view.
Item {
    id: root

    Component {
        id: fileComponent
        WatchedFile { path: "/unit/watched.json" }
    }

    TestCase {
        name: "watched-file"

        property var file: null
        property var watcher: null
        property var reader: null
        property var events: []

        function init() {
            file = createTemporaryObject(fileComponent, root);
            verify(file !== null, "the file builds");
            watcher = file.data[0];
            reader = file.data[1];
            events = [];
            file.loaded.connect(content => events.push("loaded:" + content));
            file.loadFailed.connect(error => events.push("failed:" + error));
            file.saved.connect(() => events.push("saved"));
            file.changed.connect(() => events.push("changed"));
        }

        function settleFirst() {
            reader.finishRead("first");
            compare(file.busy, false);
            events = [];
        }

        function test_first_read_is_reported() {
            compare(reader.reads, 1);
            compare(file.busy, true);
            reader.finishRead("a");
            compare(events, ["loaded:a"]);
            compare(file.busy, false);
        }

        function test_watching_view_is_never_read() {
            settleFirst();
            watcher.change();
            file.read();
            tryCompare(reader, "reads", 2);
            reader.finishRead("b");
            compare(watcher.reads, 0);
            compare(watcher.reloads, 0);
            compare(watcher.watchers, 1);
            compare(reader.watchers, 0);
        }

        function test_change_during_read_reads_again() {
            watcher.change();
            reader.finishRead("old");
            compare(events, []);
            tryCompare(reader, "reads", 2);
            reader.finishRead("new");
            compare(events, ["loaded:new"]);
            compare(file.busy, false);
        }

        function test_read_during_read_reads_again() {
            settleFirst();
            file.read();
            tryCompare(reader, "reads", 2);
            file.read();
            reader.finishRead("old");
            compare(events, []);
            tryCompare(reader, "reads", 3);
            reader.finishRead("new");
            compare(events, ["loaded:new"]);
        }

        function test_overtaken_failed_read_reads_again() {
            watcher.change();
            reader.failRead(2);
            compare(events, []);
            tryCompare(reader, "reads", 2);
            reader.finishRead("back");
            compare(events, ["loaded:back"]);
        }

        function test_change_while_idle_is_reported() {
            settleFirst();
            watcher.change();
            compare(events, ["changed"]);
            wait(0);
            compare(reader.reads, 1);
        }

        function test_change_during_write_is_reported() {
            settleFirst();
            file.write("w");
            tryCompare(reader, "live", "write");
            watcher.change();
            compare(events, ["changed"]);
            reader.finishWrite();
            compare(events, ["changed", "saved"]);
            compare(file.busy, false);
        }

        function test_read_from_a_result_handler_reaches_the_view() {
            settleFirst();
            let asked = false;
            file.loaded.connect(() => { if (!asked) { asked = true; file.read(); } });
            file.read();
            tryCompare(reader, "reads", 2);
            reader.finishRead("x");
            tryCompare(reader, "reads", 3);
            reader.finishRead("y");
            compare(events, ["loaded:x", "loaded:y"]);
            compare(file.busy, false);
        }

        function test_write_from_a_result_handler_reaches_the_view() {
            let asked = false;
            file.loaded.connect(() => { if (!asked) { asked = true; file.write("w"); } });
            reader.finishRead("x");
            tryCompare(reader, "live", "write");
            compare(reader.written, "w");
            reader.finishWrite();
            compare(events, ["loaded:x", "saved"]);
            compare(file.busy, false);
        }
    }
}
