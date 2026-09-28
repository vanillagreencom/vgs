import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Label draws one typography role: every font property and the colour come
// from the role, a theme change moves them, an unknown role is logged and
// drawn as body, and the weight reaches the variable font: a heavier weight
// leaves more ink. The bar role draws at the bar's chrome metrics with a
// line box exactly the font's height, so centring the box centres the text.
Item {
    id: root
    width: 300
    height: 150

    Rectangle { anchors.fill: parent; color: "black" }
    Label { id: body; text: "Plugin updates" }
    Label { id: eyebrow; role: "eyebrow"; text: "Community registry"; y: 30 }
    Label { id: light; text: "Weight"; y: 60; font.weight: 300; font.variableAxes: ({ wght: 300 }); color: "white" }
    Label { id: heavy; text: "Weight"; y: 90; font.weight: 800; font.variableAxes: ({ wght: 800 }); color: "white" }
    Label { id: bar; role: "bar"; text: "10"; y: 120 }
    FontMetrics { id: barMetrics; font: bar.font }

    TestCase {
        name: "label"
        when: windowShown

        function init() { UnitTheme.reset(); }

        function ink(item) {
            const img = grabImage(item);
            let n = 0;
            for (let x = 0; x < img.width; x++)
                for (let y = 0; y < img.height; y++)
                    if (img.red(x, y) > 128) n++;
            return n;
        }

        function test_role_sets_every_font_property() {
            const role = Theme.text.eyebrow;
            compare(eyebrow.font.family, role.family);
            compare(eyebrow.font.pixelSize, role.size);
            compare(eyebrow.font.weight, role.weight);
            compare(eyebrow.font.variableAxes.wght, role.weight);
            // QFont keeps letter spacing to a sixteenth of a pixel.
            fuzzyCompare(eyebrow.font.letterSpacing, role.letterSpacing * role.size, 0.07);
            compare(eyebrow.font.capitalization, Font.AllUppercase);
            compare(eyebrow.lineHeight, role.lineHeight);
            compare(String(eyebrow.color), String(Qt.color(role.color)));
            compare(body.font.capitalization, Font.MixedCase);
            compare(String(body.color), String(Qt.color(Theme.text.body.color)));
        }

        // The values are the reference's, restated here rather than read
        // from the table, so a changed row reddens this test.
        function test_bar_role_draws_the_chrome_metrics() {
            compare(bar.font.family, "JetBrains Mono");
            compare(bar.font.pixelSize, 12);
            compare(bar.font.weight, 500);
            compare(bar.font.variableAxes.wght, 500);
            fuzzyCompare(bar.font.letterSpacing, 0.02 * 12, 0.07);
            compare(bar.font.capitalization, Font.MixedCase);
            compare(bar.lineHeight, 1);
            compare(bar.lineHeightMode, Text.ProportionalHeight);
            fuzzyCompare(bar.implicitHeight, barMetrics.height, 1);
        }

        function test_theme_change_moves_the_role() {
            compare(UnitTheme.override({ text: { body: { size: 20, family: "No Such Family VGS", uppercase: true } } }), "ok");
            compare(body.font.pixelSize, 20);
            compare(body.font.capitalization, Font.AllUppercase);
            // An absent family draws with the bundled one.
            compare(body.font.family, "JetBrains Mono");
        }

        function test_unknown_role_is_logged_and_drawn_as_body() {
            const label = Qt.createQmlObject("import qs.Ui\nLabel { role: \"heading\"; text: \"x\" }", root);
            compare(label.font.pixelSize, Theme.text.body.size);
            label.destroy();
        }

        function test_weight_reaches_the_font() {
            wait(100);
            const lightInk = ink(light);
            const heavyInk = ink(heavy);
            verify(lightInk > 0, "the light label drew");
            verify(heavyInk > lightInk, "weight 800 leaves more ink than 300: " + heavyInk + " against " + lightInk);
        }
    }
}
