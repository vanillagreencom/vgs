import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Label draws one typography role: every font property and the colour come
// from the role, a theme change moves them, an unknown role is logged and
// drawn as body, and the weight reaches the variable font: a heavier weight
// leaves more ink. Reading text draws in the bundled sans family and chrome
// in the bundled mono family at the reference's metrics, and a chrome role
// with line height 1 has a line box exactly the font's height, so centring
// the box centres the text. The roles use seven sizes and no more. A
// key/value row's label and its value draw in the pair of roles whose
// capitals are within a pixel of one height, and on the row they share a
// baseline within a pixel. An absent family draws the bundled family its
// token's default names.
Item {
    id: root
    width: 300
    height: 220

    Rectangle { anchors.fill: parent; color: "black" }
    Label { id: body; text: "Plugin updates" }
    Label { id: bodyTwo; text: "Plugin updates\nready"; y: 120 }
    Label { id: eyebrow; role: "eyebrow"; text: "Community registry"; y: 30 }
    Label { id: light; text: "Weight"; y: 60; font.weight: 300; font.variableAxes: ({ wght: 300 }); color: "white" }
    Label { id: heavy; text: "Weight"; y: 90; font.weight: 800; font.variableAxes: ({ wght: 800 }); color: "white" }
    Repeater {
        id: roles
        model: Object.keys(Theme.text)
        Label { required property string modelData; role: modelData; text: "10" }
    }
    Label { id: bar; role: "bar"; text: "10"; y: 170 }
    FontMetrics { id: barMetrics; font: bar.font }
    Field { id: pair; label: "Agents running"; inline: true; width: 300; y: 190; Label { id: pairValue; role: "value"; text: "3" } }

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
            compare(eyebrow.typography.lineHeight, role.lineHeight);
            compare(String(eyebrow.color), String(Qt.color(role.color)));
            compare(body.font.capitalization, Font.MixedCase);
            compare(String(body.color), String(Qt.color(Theme.text.body.color)));
        }

        // The values are the reference's, restated here rather than read
        // from the table, so a changed row reddens this test: the family,
        // the size in pixels, the weight, the letter spacing in em, whether
        // the role draws in capitals, and the line height.
        function test_role_draws_the_reference_metrics_data() {
            const sans = "Inter Variable";
            const mono = "JetBrains Mono";
            return [
                { tag: "display", family: sans, size: 34, weight: 700, spacing: -0.02, uppercase: false, lineHeight: 1.3 },
                { tag: "h1", family: sans, size: 24, weight: 700, spacing: -0.01, uppercase: false, lineHeight: 1.333 },
                { tag: "h2", family: sans, size: 20, weight: 600, spacing: 0, uppercase: false, lineHeight: 1.4 },
                { tag: "h3", family: sans, size: 16, weight: 600, spacing: 0, uppercase: false, lineHeight: 1.5 },
                { tag: "subheading", family: sans, size: 16, weight: 400, spacing: 0, uppercase: false, lineHeight: 1.75 },
                { tag: "body", family: sans, size: 15, weight: 400, spacing: 0, uppercase: false, lineHeight: 1.6 },
                { tag: "bodyStrong", family: sans, size: 15, weight: 600, spacing: 0, uppercase: false, lineHeight: 1.6 },
                { tag: "item", family: sans, size: 15, weight: 400, spacing: 0, uppercase: false, lineHeight: 1 },
                { tag: "itemHint", family: sans, size: 13, weight: 400, spacing: 0, uppercase: false, lineHeight: 1 },
                { tag: "itemCode", family: mono, size: 13, weight: 500, spacing: 0, uppercase: false, lineHeight: 1 },
                { tag: "hint", family: sans, size: 13, weight: 400, spacing: 0, uppercase: false, lineHeight: 1.55 },
                { tag: "eyebrow", family: mono, size: 12, weight: 700, spacing: 0.18, uppercase: true, lineHeight: 1 },
                { tag: "label", family: mono, size: 12, weight: 500, spacing: 0.08, uppercase: true, lineHeight: 1 },
                { tag: "value", family: sans, size: 13, weight: 400, spacing: 0, uppercase: false, lineHeight: 1 },
                { tag: "button", family: mono, size: 12, weight: 500, spacing: 0.08, uppercase: true, lineHeight: 1 },
                { tag: "kbd", family: mono, size: 12, weight: 600, spacing: 0.02, uppercase: false, lineHeight: 1 },
                { tag: "code", family: mono, size: 13, weight: 500, spacing: 0, uppercase: false, lineHeight: 1.5 },
                { tag: "tooltip", family: sans, size: 12, weight: 500, spacing: 0, uppercase: false, lineHeight: 1.333 },
                { tag: "bar", family: mono, size: 12, weight: 500, spacing: 0.08, uppercase: true, lineHeight: 1 }
            ];
        }

        function test_role_draws_the_reference_metrics(data) {
            let label = null;
            for (let i = 0; i < roles.count; i++)
                if (roles.itemAt(i).role === data.tag) label = roles.itemAt(i);
            verify(label !== null, "a label draws role " + data.tag);
            compare(label.font.family, data.family);
            compare(label.font.pixelSize, data.size);
            compare(label.font.weight, data.weight);
            compare(label.font.variableAxes.wght, data.weight);
            // QFont keeps letter spacing to a sixteenth of a pixel.
            fuzzyCompare(label.font.letterSpacing, data.spacing * data.size, 0.07);
            compare(label.font.capitalization, data.uppercase ? Font.AllUppercase : Font.MixedCase);
            compare(label.typography.lineHeight, data.lineHeight);
        }

        // Every role of the table is a row above, so a role added without
        // its reference values reddens this test.
        function test_every_role_is_pinned() {
            compare(Object.keys(Theme.text).sort(), test_role_draws_the_reference_metrics_data().map(row => row.tag).sort());
        }

        // The scale's steps, restated: a role at a size between them adds a
        // step the hierarchy does not need.
        function test_the_scale_has_seven_steps() {
            const sizes = Object.keys(Theme.text).map(name => Theme.text[name].size);
            compare(Array.from(new Set(sizes)).sort((a, b) => a - b), [12, 13, 15, 16, 20, 24, 34]);
        }

        // A key/value row's label and its value: capitals within a pixel of
        // one height, and baselines within a pixel on the row.
        function test_a_label_and_its_value_read_as_one_line() {
            const label = pair.children.find(child => child.spacing === Theme.field.labelGap).children[0];
            compare(label.role, "label");
            const labelMetrics = Qt.createQmlObject("import QtQuick\nFontMetrics {}", root);
            labelMetrics.font = label.font;
            const valueMetrics = Qt.createQmlObject("import QtQuick\nFontMetrics {}", root);
            valueMetrics.font = pairValue.font;
            verify(Math.abs(labelMetrics.capitalHeight - valueMetrics.capitalHeight) <= 1, "capitals " + labelMetrics.capitalHeight + " and " + valueMetrics.capitalHeight);
            const keyBase = label.mapToItem(pair, 0, label.baselineOffset).y;
            const valueBase = pairValue.mapToItem(pair, 0, pairValue.baselineOffset).y;
            verify(Math.abs(keyBase - valueBase) <= 1, pair.label + " baselines " + keyBase + " and " + valueBase);
            labelMetrics.destroy();
            valueMetrics.destroy();
        }

        function test_bar_line_box_is_the_font_height() {
            compare(bar.lineHeightMode, Text.FixedHeight);
            compare(bar.lineHeight, bar.lineBox);
            compare(bar.lineBox, Math.ceil(bar.fontHeight));
            fuzzyCompare(bar.implicitHeight, barMetrics.height, 1);
        }

        function test_every_role_line_box_is_whole_pixel() {
            for (let i = 0; i < roles.count; i++) {
                const label = roles.itemAt(i);
                compare(label.lineBox, Math.round(label.lineBox), label.role);
            }
        }

        // A role that wraps sets its line box on the 4 px grid at the
        // default font size, so wrapped text keeps the layout's rhythm.
        function test_multi_line_roles_sit_on_the_grid() {
            let checked = 0;
            for (let i = 0; i < roles.count; i++) {
                const label = roles.itemAt(i);
                if (label.typography.lineHeight <= 1) continue;
                compare(label.lineBox % 4, 0, label.role + " line box " + label.lineBox);
                checked += 1;
            }
            verify(checked >= 9, "the role walk found " + checked + " multi-line roles; the walk is broken");
        }

        function test_body_line_height_uses_font_size_multiple() {
            const lineBox = Math.round(15 * 1.6);
            compare(bodyTwo.lineHeightMode, Text.FixedHeight);
            compare(bodyTwo.lineHeight, lineBox);
            fuzzyCompare(bodyTwo.implicitHeight, 2 * lineBox, 1);
        }

        function test_measurements_read_back() {
            verify(bodyTwo.halfLeading > 0, "body text has fixed leading");
            fuzzyCompare(bar.halfLeading, 0, 0.1);
            verify(eyebrow.capCentre > 0, "the cap centre is measured");
            verify(eyebrow.opticalWidth < eyebrow.implicitWidth, "tracked text has a smaller optical width");
            fuzzyCompare(eyebrow.topForCapCenter(Theme.badge.size.sm.height) + eyebrow.capCentre, Theme.badge.size.sm.height / 2, 1);
        }

        // expected-log: theme: font=No Such Family VGS unavailable; drawing JetBrains Mono -- the eyebrow names an absent family on purpose
        // expected-log: theme: font=No Such Family VGS unavailable; drawing Inter Variable -- the body names an absent family on purpose
        function test_theme_change_moves_the_role() {
            compare(UnitTheme.override({ text: { body: { size: 20, family: "No Such Family VGS", uppercase: true }, eyebrow: { family: "No Such Family VGS" } } }), "ok");
            compare(body.font.pixelSize, 20);
            compare(body.font.capitalization, Font.AllUppercase);
            // An absent family draws the bundled family its token's default
            // names: sans for body, mono for the eyebrow.
            compare(body.font.family, "Inter Variable");
            compare(eyebrow.font.family, "JetBrains Mono");
        }

        // expected-log: Label: no text role named "heading" -- the test names an unknown role on purpose
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
