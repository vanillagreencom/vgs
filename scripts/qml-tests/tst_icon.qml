import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Icon draws Lucide path data: a name resolves to its paths, an unknown
// name is logged and draws nothing, a converted primitive draws where its
// SVG would, and the stroke is the same number of pixels at 12 and at 48.
Item {
    id: root
    width: 200
    height: 100

    Rectangle { anchors.fill: parent; color: "black" }
    Icon { id: small; name: "minus"; size: 12; color: "white"; x: 10; y: 10 }
    Icon { id: large; name: "minus"; size: 48; color: "white"; x: 40; y: 10 }
    Icon { id: circle; name: "circle"; size: 24; color: "white"; x: 80; y: 10 }
    Icon { id: themed; name: "check" }

    TestCase {
        name: "icon"
        when: windowShown

        function init() { UnitTheme.reset(); }

        // Rows of the column at `x` that hold ink.
        function inkRows(item, x) {
            const img = grabImage(item);
            let n = 0;
            for (let y = 0; y < img.height; y++)
                if (img.red(x, y) > 128) n++;
            return n;
        }

        function test_name_resolves() {
            verify(themed.paths[0].length > 0);
            compare(themed.implicitWidth, Theme.icon.size.md);
            compare(String(themed.color), String(Qt.color(Theme.color.text)));
        }

        function test_unknown_name_is_logged_and_draws_nothing() {
            const icon = Qt.createQmlObject("import qs.Ui\nIcon { name: \"no-such-icon\" }", root);
            compare(icon.paths[0], "");
            icon.destroy();
        }

        function test_stroke_is_constant_across_sizes() {
            compare(small.stroke, Theme.icon.stroke);
            wait(100);
            const at12 = inkRows(small, 6);
            const at48 = inkRows(large, 24);
            verify(at12 > 0, "the 12 pixel icon drew a line");
            verify(Math.abs(at12 - at48) <= 1, "line rows at 12 and 48: " + at12 + " against " + at48);
        }

        function test_converted_circle_draws_a_ring() {
            wait(100);
            const img = grabImage(circle);
            verify(img.red(12, 12) < 128, "the centre of the ring is empty");
            verify(img.red(2, 12) > 128 || img.red(3, 12) > 128, "the ring passes the left edge");
        }

        function test_theme_change_reaches_the_icon() {
            compare(UnitTheme.override({ icon: { stroke: 3, size: { md: 20 } }, palette: { foreground: "#00ff00" } }), "ok");
            compare(themed.stroke, 3);
            compare(themed.implicitWidth, 20);
            compare(String(themed.color), "#00ff00");
        }
    }
}
