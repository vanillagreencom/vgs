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
    Icon { id: cross; name: "x"; size: 24; color: "white"; x: 120; y: 10 }
    Icon { id: chevron; name: "chevron-left"; size: 24; color: "white"; x: 160; y: 10 }

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

        // The painted extent of chevron-left, M15 18 l-6-6 6-6: x 9 to 15
        // and y 6 to 18 of the 24 unit box, grown by half the stroke. The
        // circle, two arcs of radius 10 around (12, 12), reaches 2 to 22 on
        // both axes: only the arc branch places those extremes, 10 units
        // from the arcs' ends.
        function test_painted_extent_reads_the_path() {
            const half = Theme.icon.stroke / 2;
            compare(chevron.painted, [9 - half, 6 - half, 15 + half, 18 + half]);
            const box = circle.painted;
            for (let i = 0; i < 4; i++)
                fuzzyCompare(box[i], [2 - half, 2 - half, 22 + half, 22 + half][i], 1e-6);
        }

        // No ink lies outside the painted extent.
        function test_painted_extent_holds_the_ink() {
            wait(100);
            const img = grabImage(chevron);
            let left = chevron.size, right = -1;
            for (let x = 0; x < img.width; x++)
                for (let y = 0; y < img.height; y++)
                    if (img.red(x, y) > 40) { left = Math.min(left, x); right = Math.max(right, x); }
            verify(right >= 0, "the chevron drew");
            verify(left >= Math.floor(chevron.painted[0]), "ink at " + left + " starts before the extent " + chevron.painted[0]);
            verify(right <= Math.ceil(chevron.painted[2]), "ink at " + right + " ends after the extent " + chevron.painted[2]);
        }

        function test_name_resolves() {
            verify(themed.paths[0].length > 0);
            compare(themed.implicitWidth, Theme.icon.size.md);
            compare(String(themed.color), String(Qt.color(Theme.color.text)));
        }

        // expected-log: Icon: no icon named "no-such-icon" -- the test names an unknown icon on purpose
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

        function test_second_path_starts_at_the_origin() {
            wait(100);
            const img = grabImage(cross);
            // Both strokes of the x cross the centre and reach each corner.
            verify(img.red(12, 12) > 128, "the strokes cross at the centre");
            verify(img.red(6, 18) > 128 || img.red(6, 17) > 128, "the first stroke reaches the bottom-left");
            verify(img.red(18, 18) > 128 || img.red(17, 17) > 128, "the second stroke reaches the bottom-right");
        }

        function test_filled_node_keeps_its_stroke() {
            wait(100);
            const icon = Qt.createQmlObject("import qs.Ui\nIcon { name: \"palette\"; size: 48; color: \"white\" }", root, "palette");
            icon.x = 150; icon.y = 40;
            wait(100);
            const img = grabImage(icon);
            // The dot at (13, 6.5) in the box is a 0.5 unit circle: filled and
            // stroked at 1.5 pixels it covers its centre pixel at twice the box.
            verify(img.red(26, 13) > 128, "a filled dot is drawn");
            icon.destroy();
        }

        function test_theme_change_reaches_the_icon() {
            compare(UnitTheme.override({ icon: { stroke: 3, size: { md: 20 } }, palette: { foreground: "#00ff00" } }), "ok");
            compare(themed.stroke, 3);
            compare(themed.implicitWidth, 20);
            compare(String(themed.color), "#00ff00");
        }
    }
}
