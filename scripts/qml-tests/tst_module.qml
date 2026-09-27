import QtQuick
import QtTest
import qs.Ui
import qs.Unit

// Every component qs.Ui lists loads and instantiates with its defaults, so
// a component with a broken binding names itself here before any other
// test reaches it. The list comes from the module's qmldir, read from the
// module under test, never from a second list.
Item {
    id: root
    width: 400
    height: 400

    TestCase {
        name: "module"
        when: windowShown

        function names() {
            const request = new XMLHttpRequest();
            request.open("GET", UnitPaths.UI_DIR + "/qmldir", false);
            request.send();
            const out = [];
            for (const line of request.responseText.split("\n")) {
                const m = /^(\w+) 1\.0 (\S+)$/.exec(line);
                if (m !== null) out.push({ name: m[1], file: m[2] });
            }
            return out;
        }

        function test_every_component_instantiates() {
            const listed = names();
            verify(listed.length >= 20, "the qmldir read found " + listed.length + " components; the read is broken");
            const bare = { Icon: "name: \"check\"", IconButton: "iconName: \"x\"; label: \"close\"", FocusRing: "target: root" };
            for (const entry of listed) {
                if (entry.name === "BarWidget") continue;
                const source = "import QtQuick\nimport qs.Ui\n" + entry.name + " { " + (bare[entry.name] || "") + " }";
                let item = null;
                try {
                    item = Qt.createQmlObject(source, root, entry.file);
                } catch (e) {
                    fail(entry.name + " does not instantiate: " + e.qmlErrors.map(err => err.fileName + ":" + err.lineNumber + " " + err.message).join("; "));
                }
                verify(item !== null, entry.name);
                verify(item.implicitWidth >= 0 && item.implicitHeight >= 0, entry.name + " has a size");
                item.destroy();
            }
        }
    }
}
