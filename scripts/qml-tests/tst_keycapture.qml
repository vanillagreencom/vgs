import QtQuick
import QtTest
import Quickshell.Hyprland
import qs.Core

// The key capture owner, KeyCapture.qml, through the `capture` member the
// shortcut capability hands a plugin: which control holds the keyboard,
// the pass-through requests it sends Compositor (a stand-in that records
// them and takes their answers by hand), every end that leaves the submap,
// the submap Hyprland reports, a failed enter, a timeout, and the user's
// binds it reads from HyprlandState (a stand-in source here) for the
// conflict hint.
Item {
    id: root
    // HyprlandState's binds members, set by hand.
    QtObject {
        id: source
        property var foreignKeys: null
        property string bindsFailure: ""
        property int reads: 0
        function readBinds() { reads += 1; }
    }
    ShortcutRegistry { id: registry; bindsSource: source }
    property var disposers: []
    property var capture: registry.provider(context("acme.keys")).capture
    property var other: registry.provider(context("acme.other")).capture

    function context(id) {
        return { id: id, onDispose: fn => {
            let pending = true;
            const dispose = () => { if (pending) { pending = false; fn(); } };
            root.disposers = root.disposers.concat([dispose]);
            return dispose;
        } };
    }

    Item { id: first }
    Item { id: second }
    Component { id: transient; Item {} }
    Component { id: fresh; ShortcutRegistry {} }

    TestCase {
        name: "key-capture"

        function init() {
            Registry.hyprlandSections = [{ id: "acme.keys", binds: [{ shortcut: "open", key: "SUPER+SPACE" }] }];
            Compositor.reset();
        }

        function cleanup() {
            root.capture.end(first, "cancel");
            root.capture.end(second, "cancel");
            Compositor.answerAll();
            Compositor.reset();
            source.foreignKeys = null;
            source.bindsFailure = "";
            source.reads = 0;
        }

        function submap(name) { Hyprland.rawEvent({ name: "submap", data: name }); }
        function sent() { return JSON.stringify(Compositor.requests); }
        // The registry's KeyCapture, whose start time the timeout case moves back.
        function owner() { return registry.data.find(child => child.began !== undefined); }

        function test_begin_enters_and_commit_leaves() {
            compare(root.capture.begin(first), "ok");
            compare(root.capture.holder, first);
            compare(root.capture.passthrough, false);
            compare(sent(), '["enter"]');
            Compositor.answer(0, "ok");
            submap("vgs:passthrough");
            compare(root.capture.passthrough, true);
            compare(root.capture.failed, false);
            root.capture.end(first, "commit");
            compare(root.capture.holder, null);
            compare(root.capture.passthrough, false);
            compare(sent(), '["enter","leave"]');
            compare(JSON.stringify([root.capture.ended.item === first, root.capture.ended.reason]), '[true,"commit"]');
        }

        function test_cancel_leaves_before_hyprland_answers() {
            root.capture.begin(first);
            root.capture.end(first, "cancel");
            compare(root.capture.holder, null);
            compare(sent(), '["enter","leave"]');
            submap("vgs:passthrough");
            compare(root.capture.passthrough, false);
        }

        function test_only_the_holder_ends_it() {
            root.capture.begin(first);
            root.capture.end(second, "commit");
            compare(root.capture.holder, first);
            compare(sent(), '["enter"]');
        }

        function test_a_second_begin_by_the_holder_sends_nothing() {
            root.capture.begin(first);
            root.capture.begin(first);
            compare(sent(), '["enter"]');
        }

        function test_a_newer_holder_ends_the_first() {
            root.capture.begin(first);
            root.other.begin(second);
            compare(root.capture.holder, second);
            compare(sent(), '["enter","leave"]');
            Compositor.answer(0, "ok");
            Compositor.answer(1, "ok");
            compare(sent(), '["enter","leave","enter"]');
        }

        // The quick re-arm: the first capture's enter and leave are still
        // queued when the second begins, so their submap events come after
        // its begin and belong to the first.
        function test_an_earlier_captures_events_leave_a_newer_one() {
            root.capture.begin(first);
            root.capture.end(first, "cancel");
            root.capture.begin(second);
            compare(sent(), '["enter","leave"]');
            Compositor.answer(0, "ok");
            submap("vgs:passthrough");
            submap("");
            compare(root.capture.holder, second);
            Compositor.answer(1, "ok");
            compare(sent(), '["enter","leave","enter"]');
            submap("vgs:passthrough");
            compare(root.capture.holder, second);
            compare(root.capture.passthrough, true);
        }

        function test_a_destroyed_holder_leaves() {
            const item = transient.createObject(root);
            root.capture.begin(item);
            submap("vgs:passthrough");
            item.destroy();
            wait(0); // QObject.destroy() completes after the current event turn.
            compare(root.capture.holder, null);
            compare(sent(), '["enter","leave"]');
        }

        function test_instance_teardown_leaves() {
            const ctx = root.context("acme.gone");
            const capture = registry.provider(ctx).capture;
            capture.begin(first);
            const pending = root.disposers;
            root.disposers = [];
            for (const dispose of pending) dispose();
            compare(capture.holder, null);
            compare(sent(), '["enter","leave"]');
        }

        function test_hyprland_leaving_ends_the_capture() {
            root.capture.begin(first);
            submap("vgs:passthrough");
            submap("");
            compare(root.capture.holder, null);
            compare(sent(), '["enter"]');
            compare(root.capture.ended.reason, "compositor");
        }

        function test_another_submap_ends_the_capture() {
            root.capture.begin(first);
            submap("vgs:passthrough");
            submap("vgs:capture");
            compare(root.capture.holder, null);
            compare(sent(), '["enter"]');
        }

        function test_a_submap_change_before_the_enter_keeps_it() {
            root.capture.begin(first);
            submap("");
            compare(root.capture.holder, first);
            compare(root.capture.passthrough, false);
        }

        function test_a_failed_enter_is_reported_and_keeps_capturing() {
            root.capture.begin(first);
            Compositor.answer(0, "hl.dispatch: vgs:passthrough: the focused window is not a vgs window");
            compare(root.capture.failed, true);
            compare(root.capture.holder, first);
            root.capture.end(first, "cancel");
            compare(root.capture.failed, false);
            Compositor.answerAll();
            Compositor.refuse = "refused: passthrough=enter session=classic";
            root.capture.begin(second);
            compare(root.capture.failed, true);
        }

        function test_an_enter_answer_for_an_earlier_capture_is_dropped() {
            root.capture.begin(first);
            root.capture.end(first, "cancel");
            Compositor.answer(1, "ok");
            root.capture.begin(second);
            Compositor.answer(0, "exit=1");
            compare(root.capture.failed, false);
        }

        function test_an_end_after_the_timeout_is_a_timeout() {
            root.capture.begin(first);
            submap("vgs:passthrough");
            owner().began = Date.now() - root.capture.timeoutMs;
            submap("");
            compare(JSON.stringify([root.capture.ended.item === first, root.capture.ended.reason]), '[true,"timeout"]');
            compare(sent(), '["enter"]');
        }

        function test_keys_are_named_by_the_judge() {
            compare(JSON.stringify(root.capture.keyFor(Qt.Key_Space, Qt.MetaModifier)), '{"kind":"key","key":"SUPER+SPACE"}');
        }

        function test_conflicts_read_the_user_binds() {
            source.foreignKeys = ["SUPER+SPACE"];
            compare(JSON.stringify(root.capture.conflicts("super+space", "acme.other", "x")), '{"plugins":[{"id":"acme.keys","shortcut":"open"}],"user":true,"binds":"read"}');
            source.foreignKeys = [];
            compare(JSON.stringify(root.capture.conflicts("SUPER+SPACE", "acme.other", "x")), '{"plugins":[{"id":"acme.keys","shortcut":"open"}],"user":false,"binds":"read"}');
        }

        function test_a_question_and_a_capture_want_the_binds() {
            const made = fresh.createObject(root, { bindsSource: source });
            compare(made.keyCapture.wantsBinds, false);
            const asked = root.context("acme.fresh");
            const asker = made.provider(asked).capture;
            compare(asker.conflicts("SUPER+SPACE", "acme.other", "x").binds, "unread");
            wait(0); // the want is recorded after the question returns, Qt.callLater.
            compare(made.keyCapture.wantsBinds, true);
            const pending = root.disposers;
            root.disposers = [];
            for (const dispose of pending) dispose();
            compare(made.keyCapture.wantsBinds, false);
            asker.begin(first);
            compare(made.keyCapture.wantsBinds, true);
            asker.end(first, "cancel");
            compare(made.keyCapture.wantsBinds, false);
            made.destroy();
        }

        function test_a_failed_read_is_named_and_asked_again_once() {
            source.bindsFailure = "refused: binds=unparsed";
            compare(root.capture.conflicts("SUPER+SPACE", "acme.other", "x").binds, "failed");
            wait(0);
            compare(source.reads, 1);
            compare(root.capture.conflicts("SUPER+SPACE", "acme.other", "x").binds, "failed");
            wait(0);
            compare(source.reads, 1);
            source.bindsFailure = "";
            source.foreignKeys = [];
            compare(root.capture.conflicts("SUPER+SPACE", "acme.other", "x").binds, "read");
            source.bindsFailure = "refused: binds=unparsed";
            root.capture.conflicts("SUPER+SPACE", "acme.other", "x");
            wait(0);
            compare(source.reads, 2);
        }
    }
}
