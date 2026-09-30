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
