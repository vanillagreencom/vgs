import QtQuick
import QtTest
import qs.Core

Item {
    id: root
    ShortcutRegistry { id: registry }
    property var provider: registry.provider({ id: "acme.keys" })
    property var other: registry.provider({ id: "acme.other" })
    readonly property string bound: JSON.stringify(provider.keys)
    readonly property string otherBound: JSON.stringify(other.keys)
    property var disposers: []
    property var edges: []
    property var heldObject: null
    property var releaseObject: null

    TestCase {
        name: "shortcut-registry"

        function sections(key) {
            return [
                { id: "acme.keys", binds: [{ shortcut: "talk", key: key }] },
                { id: "acme.other", binds: [{ shortcut: "toggle", key: "SUPER+F1" }] }
            ];
        }

        function init() {
            Registry.hyprlandSections = sections("SUPER+code:108");
            root.edges = [];
            root.disposers = [];
        }

        function cleanup() {
            for (const dispose of root.disposers) dispose();
            root.disposers = [];
            wait(0); // QObject.destroy() completes after the current event turn.
        }

        function context(id) {
            return { id: id, onDispose: fn => {
                let pending = true;
                const dispose = () => { if (pending) { pending = false; fn(); } };
                root.disposers = root.disposers.concat([dispose]);
                return dispose;
            } };
        }

        function hold(name) {
            const provider = registry.provider(context("acme.keys"));
            const dispose = provider.register(name, "hold fixture",
                () => root.edges = root.edges.concat([name + "-down"]),
                () => root.edges = root.edges.concat([name + "-up"]));
            return { dispose: dispose, object: registry.shortcuts["acme.keys:" + name] };
        }

        function test_hold_edges_and_unrelated_release() {
            const talk = hold("talk").object;
            const other = hold("other").object;
            compare(talk.companion.name, "talk.release");
            compare(talk.companion.appid, "acme.keys");
            other.companion.released();
            talk.companion.released();
            compare(JSON.stringify(root.edges), '[]');
            talk.pressed();
            talk.pressed();
            talk.released(); // The main bind's native edge does not own hold completion.
            other.companion.released();
            compare(JSON.stringify(root.edges), '["talk-down"]');
            talk.companion.released();
            talk.companion.released();
            compare(JSON.stringify(root.edges), '["talk-down","talk-up"]');
            talk.pressed();
            talk.companion.released();
            compare(JSON.stringify(root.edges), '["talk-down","talk-up","talk-down","talk-up"]');
        }

        function test_key_changes_cancel_hold() {
            for (const key of [null, "SUPER+SHIFT+code:108"]) {
                Registry.hyprlandSections = sections("SUPER+code:108");
                const talk = hold("talk");
                talk.object.pressed();
                Registry.hyprlandSections = sections(key);
                tryVerify(() => talk.object.stroke.kind === "idle");
                talk.object.companion.released();
                compare(JSON.stringify(root.edges), '["talk-down","talk-up"]');
                talk.dispose();
                root.edges = [];
            }
        }

        function test_dispose_releases_both_objects() {
            const talk = hold("talk");
            root.heldObject = talk.object;
            root.releaseObject = talk.object.companion;
            compare(root.disposers.length, 1);
            talk.object.pressed();
            talk.dispose();
            talk.dispose();
            compare(registry.shortcuts["acme.keys:talk"], undefined);
            talk.object.pressed();
            talk.object.companion.released();
            compare(JSON.stringify(root.edges), '["talk-down","talk-up"]');
            wait(0);
            compare(root.heldObject, null);
            compare(root.releaseObject, null);
        }

        function test_throwing_release_still_destroys_objects() {
            const provider = registry.provider(context("acme.keys"));
            const dispose = provider.register("throwing", "", () => {}, () => { throw new Error("planted release"); });
            const shortcut = registry.shortcuts["acme.keys:throwing"];
            root.heldObject = shortcut;
            root.releaseObject = shortcut.companion;
            shortcut.pressed();
            let error = "";
            try { dispose(); } catch (e) { error = e.message; }
            compare(error, "planted release");
            compare(registry.shortcuts["acme.keys:throwing"], undefined);
            wait(0);
            compare(root.heldObject, null);
            compare(root.releaseObject, null);
        }

        function test_ordinary_registration_and_refusals() {
            const provider = registry.provider(context("acme.keys"));
            provider.register("plain", "ordinary", () => root.edges = root.edges.concat(["plain"]));
            const plain = registry.shortcuts["acme.keys:plain"];
            compare(plain.companion, null);
            plain.pressed();
            plain.pressed();
            plain.released();
            compare(JSON.stringify(root.edges), '["plain","plain"]');
            for (const row of [
                ["bad-press", null, undefined, "handler=not-a-function"],
                ["bad-release", () => {}, null, "release-handler=not-a-function"],
                ["plain", () => {}, undefined, "held"]
            ]) {
                let error = "";
                try { provider.register(row[0], "", row[1], row[2]); }
                catch (e) { error = e.message; }
                compare(error, "refused: shortcut=" + (row[3] === "held" ? "acme.keys:" : "") + row[0] + " " + row[3]);
            }
        }

        function test_reactive_own_keys() {
            compare(root.bound, '{"talk":"SUPER+code:108"}');
            compare(root.otherBound, '{"toggle":"SUPER+F1"}');
            Registry.hyprlandSections = sections("SUPER+SHIFT+code:108");
            compare(root.bound, '{"talk":"SUPER+SHIFT+code:108"}');
            compare(root.otherBound, '{"toggle":"SUPER+F1"}');
            Registry.hyprlandSections = sections(null);
            compare(root.bound, '{"talk":null}');
            compare(root.provider.keys.missing, undefined);
            compare(root.provider.keys.toggle, undefined);
            Registry.hyprlandSections = [];
            compare(root.bound, '{}');
        }

        function test_mutation_is_local() {
            const read = root.provider.keys;
            read.talk = "planted";
            read.toggle = "planted";
            compare(JSON.stringify(root.provider.keys), '{"talk":"SUPER+code:108"}');
            try { root.provider.keys = { talk: "planted" }; } catch (e) {}
            compare(JSON.stringify(root.provider.keys), '{"talk":"SUPER+code:108"}');
        }
    }
}
