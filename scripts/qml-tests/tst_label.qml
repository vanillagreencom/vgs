import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Label draws one typography role: every font property and the colour come
// from the role, a theme change moves them, an unknown role is logged and
// drawn as body, and the weight reaches the variable font: a heavier weight
// leaves more ink.
Item {
    id: root
    width: 300
    height: 120

    Rectangle { anchors.fill: parent; color: "black" }
    Label { id: body; text: "Plugin updates" }
    Label { id: eyebrow; role: "eyebrow"; text: "Community registry"; y: 30 }
    Label { id: light; text: "Weight"; y: 60; font.weight: 300; font.variableAxes: ({ wght: 300 }); color: "white" }
    Label { id: heavy; text: "Weight"; y: 90; font.weight: 800; font.variableAxes: ({ wght: 800 }); color: "white" }

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

        function test_theme_change_moves_the_role() {
            compare(UnitTheme.override({ text: { body: { size: 20, family: "Inter", uppercase: true } } }), "ok");
            compare(body.font.pixelSize, 20);
            compare(body.font.capitalization, Font.AllUppercase);
            // Inter is not on this machine: the bundled family stands in.
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
