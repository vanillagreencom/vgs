import QtQuick
import QtTest
import Quickshell.Hyprland
import qs.Core

// The key capture owner, KeyCapture.qml, through the `capture` member the
// shortcut capability hands a plugin: which control holds the keyboard,
// the pass-through requests it sends Compositor (a stand-in that records
// them), every end that leaves the submap, the submap Hyprland reports,
// and the user's binds it reads for the conflict hint.
Item {
    id: root
    ShortcutRegistry { id: registry }
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

    TestCase {
        name: "key-capture"

        function init() {
            Registry.hyprlandSections = [{ id: "acme.keys", binds: [{ shortcut: "open", key: "SUPER+SPACE" }] }];
            Compositor.reset();
        }

        function cleanup() {
            root.capture.end(first, "cancel");
            root.capture.end(second, "cancel");
            Compositor.reset();
        }

        function submap(name) { Hyprland.rawEvent({ name: "submap", data: name }); }

        function test_begin_enters_and_commit_leaves() {
            compare(root.capture.begin(first), "ok");
            compare(root.capture.holder, first);
            compare(root.capture.passthrough, false);
            compare(JSON.stringify(Compositor.requests), '["enter"]');
            submap("vgs:passthrough");
            compare(root.capture.passthrough, true);
            root.capture.end(first, "commit");
            compare(root.capture.holder, null);
            compare(root.capture.passthrough, false);
            compare(JSON.stringify(Compositor.requests), '["enter","leave"]');
        }

        function test_cancel_leaves_before_hyprland_answers() {
            root.capture.begin(first);
            root.capture.end(first, "cancel");
            compare(root.capture.holder, null);
            compare(JSON.stringify(Compositor.requests), '["enter","leave"]');
            submap("vgs:passthrough");
            compare(root.capture.passthrough, false);
        }

        function test_only_the_holder_ends_it() {
            root.capture.begin(first);
            root.capture.end(second, "commit");
            compare(root.capture.holder, first);
            compare(JSON.stringify(Compositor.requests), '["enter"]');
        }

        function test_a_second_begin_by_the_holder_sends_nothing() {
            root.capture.begin(first);
            root.capture.begin(first);
            compare(JSON.stringify(Compositor.requests), '["enter"]');
        }

        function test_a_newer_holder_ends_the_first() {
            root.capture.begin(first);
            root.other.begin(second);
            compare(root.capture.holder, second);
            compare(JSON.stringify(Compositor.requests), '["enter","leave","enter"]');
        }

        function test_a_destroyed_holder_leaves() {
            const item = transient.createObject(root);
            root.capture.begin(item);
            submap("vgs:passthrough");
            item.destroy();
            wait(0); // QObject.destroy() completes after the current event turn.
            compare(root.capture.holder, null);
            compare(JSON.stringify(Compositor.requests), '["enter","leave"]');
        }

        function test_instance_teardown_leaves() {
            const ctx = root.context("acme.gone");
            const capture = registry.provider(ctx).capture;
            capture.begin(first);
            const pending = root.disposers;
            root.disposers = [];
            for (const dispose of pending) dispose();
            compare(capture.holder, null);
            compare(JSON.stringify(Compositor.requests), '["enter","leave"]');
        }

        function test_hyprland_leaving_ends_the_capture() {
            root.capture.begin(first);
            submap("vgs:passthrough");
            submap("");
            compare(root.capture.holder, null);
            compare(JSON.stringify(Compositor.requests), '["enter"]');
        }

        function test_another_submap_ends_the_capture() {
            root.capture.begin(first);
            submap("vgs:passthrough");
            submap("vgs:capture");
            compare(root.capture.holder, null);
            compare(JSON.stringify(Compositor.requests), '["enter"]');
        }

        function test_a_submap_change_before_the_enter_keeps_it() {
            root.capture.begin(first);
            submap("");
            compare(root.capture.holder, first);
            compare(root.capture.passthrough, false);
        }

        function test_keys_are_named_by_the_judge() {
            compare(JSON.stringify(root.capture.keyFor(Qt.Key_Space, Qt.MetaModifier)), '{"kind":"key","key":"SUPER+SPACE"}');
        }

        function test_conflicts_read_the_user_binds() {
            const binds = JSON.stringify([
                { submap: "", modmask: 64, key: "SPACE", description: "acme.keys:open", mouse: false },
                { submap: "", modmask: 64, key: "space", description: "Menu", mouse: false }
            ]);
            root.capture.begin(first);
            Compositor.answerBinds(binds);
            compare(JSON.stringify(root.capture.conflicts("SUPER+SPACE", "acme.other", "x")), '{"plugins":[{"id":"acme.keys","shortcut":"open"}],"user":["Menu"]}');
            Compositor.reset();
            Hyprland.rawEvent({ name: "configreloaded", data: "" });
            compare(Compositor.bindsWaiting.length, 1);
            Compositor.answerBinds(JSON.stringify([]));
            compare(JSON.stringify(root.capture.conflicts("SUPER+SPACE", "acme.other", "x").user), "[]");
        }
    }
}
