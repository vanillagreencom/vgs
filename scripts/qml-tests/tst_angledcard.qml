import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// AngledCard: the parallelogram its corners state, leaning either way; the
// clip wired as a mask of that parallelogram over the content; the dim wash
// over a card that is not selected and none over one that is, either way
// when `dimmed` is set; the lifted wash and outline of a hovered card and
// none on a hovered selected one; the outline's width and colour for each
// state, read and drawn; and all of it under the default theme and a light theme that
// moves the palette, the skew and the selected width. Expected values are
// worked by hand from the defaults in Tokens.js, never read from Theme.
//
// The unit runner draws with Qt Quick's software adaptation, which draws no
// MultiEffect, so the clipped content is absent from a grab: the clip is
// read as the effect's mask and the mask's path, and the outline, drawn
// outside the effect, is read back as pixels too.
Item {
    id: root
    width: 460
    height: 240

    Rectangle { anchors.fill: parent; color: "black" }
    AngledCard {
        id: plain
        x: 20; y: 20; width: 200; height: 100
        Rectangle { anchors.fill: parent; color: "white" }
    }
    AngledCard {
        id: chosen
        x: 240; y: 20; width: 200; height: 100
        selected: true
        Rectangle { anchors.fill: parent; color: "white" }
    }
    AngledCard {
        id: mirrored
        x: 20; y: 130; width: 200; height: 100
        skew: -28
    }

    TestCase {
        name: "angledCard"
        when: windowShown

        function init() {
            UnitTheme.reset();
            chosen.selected = true;
            plain.hovered = false;
            chosen.hovered = false;
        }

        function childrenOf(card, type) { return card.children.filter(child => String(child).startsWith(type + "(")); }
        function mask(card) { return childrenOf(card, "QQuickShape")[0]; }
        function edge(card) { return childrenOf(card, "QQuickShape")[1]; }
        function effect(card) { return childrenOf(card, "QQuickMultiEffect")[0]; }
        function wash(card) { return childrenOf(card, "QQuickItem")[0].children[1]; }
        function pathOf(shape) { return shape.data.find(child => String(child).startsWith("QQuickShapePath")); }
        function points(list) { return Array.from(list).map(p => [p.x, p.y]); }

        function test_corners_lean_by_the_skew() {
            compare(plain.skew, 28);
            compare(points(plain.corners), [[28, 0], [200, 0], [172, 100], [0, 100]]);
            compare(points(mirrored.corners), [[0, 0], [172, 0], [200, 100], [28, 100]]);
        }

        // The mask is the closed parallelogram, filled opaque, so its alpha
        // keeps the content inside and drops it outside.
        function test_content_is_masked_by_the_parallelogram() {
            for (const card of [plain, mirrored]) {
                const fx = effect(card);
                verify(fx !== undefined, "the content is drawn through an effect");
                verify(fx.maskEnabled, "the effect masks");
                verify(fx.maskSource === mask(card), "the effect's mask is the card's mask shape");
                verify(!mask(card).visible && mask(card).layer.enabled, "the mask is a hidden layer");
                const path = pathOf(mask(card));
                compare(Qt.color(path.fillColor).a, 1);
                compare(Qt.color(path.strokeColor).a, 0);
                compare(points(path.pathElements[0].path), points(card.corners).concat([points(card.corners)[0]]));
            }
            compare(points(pathOf(mask(plain)).pathElements[0].path), [[28, 0], [200, 0], [172, 100], [0, 100], [28, 0]]);
        }

        // alpha(#000000, 0.42): 0.42 * 255 = 107.1, 0x6b.
        function test_a_card_not_selected_is_washed() {
            compare(String(wash(plain).color), "#6b000000");
            verify(wash(plain).visible);
            verify(!wash(chosen).visible);
        }

        // Under the pointer the wash is alpha(#000000, 0.21): 0.21 * 255 =
        // 53.55, 0x36, and the outline textMuted, mix(#d7d7d9, #000000,
        // 0.21): 215 * 0.79 = 169.85, 217 * 0.79 = 171.43. A selected card
        // keeps its unwashed accent outline.
        function test_a_hovered_card_lifts_its_wash_and_outline() {
            plain.hovered = true;
            tryCompare(wash(plain), "color", Qt.color("#36000000"));
            compare(String(pathOf(edge(plain)).strokeColor), "#aaaaab");
            compare(pathOf(edge(plain)).strokeWidth, 1);
            chosen.hovered = true;
            verify(!wash(chosen).visible);
            compare(String(pathOf(edge(chosen)).strokeColor), "#ff5a36");
            compare(pathOf(edge(chosen)).strokeWidth, 3);
            plain.hovered = false;
            tryCompare(wash(plain), "color", Qt.color("#6b000000"));
            compare(String(pathOf(edge(plain)).strokeColor), "#3a3a3b");
        }

        function test_dimmed_is_set_apart_from_selected() {
            const undimmed = Qt.createQmlObject("import qs.Ui\nAngledCard { dimmed: false }", root, "undimmed");
            const dimmed = Qt.createQmlObject("import qs.Ui\nAngledCard { selected: true; dimmed: true }", root, "dimmed");
            verify(!wash(undimmed).visible, "an undimmed card is not washed");
            verify(wash(dimmed).visible, "a dimmed selected card is washed");
            undimmed.destroy();
            dimmed.destroy();
        }

        // borderStrong is mix(#000000, #d7d7d9, 0.27): 215 * 0.27 = 58.05,
        // 217 * 0.27 = 58.59. The outline follows the parallelogram.
        function test_outline_width_and_colour_follow_the_state() {
            compare(points(pathOf(edge(plain)).pathElements[0].path), [[28, 0], [200, 0], [172, 100], [0, 100], [28, 0]]);
            compare(pathOf(edge(plain)).strokeWidth, 1);
            compare(String(pathOf(edge(plain)).strokeColor), "#3a3a3b");
            compare(pathOf(edge(chosen)).strokeWidth, 3);
            compare(String(pathOf(edge(chosen)).strokeColor), "#ff5a36");
            chosen.selected = false;
            compare(pathOf(edge(chosen)).strokeWidth, 1);
            compare(String(pathOf(edge(chosen)).strokeColor), "#3a3a3b");
        }

        // The outline is drawn: the top edge's row in the accent.
        function test_outline_is_drawn_on_the_edge() {
            wait(50);
            const img = grabImage(chosen);
            compare([img.red(100, 0), img.green(100, 0), img.blue(100, 0)], [255, 90, 54]);
        }

        // A light theme: alpha(#ffffff, 0.42) for the wash; borderStrong is
        // mix(#ffffff, #000000, 0.27): 255 * 0.73 = 186.15.
        function test_a_theme_moves_every_value() {
            compare(UnitTheme.override({
                palette: { background: "#ffffff", foreground: "#000000", accent: "#0000ff" },
                angledCard: { skew: 40, selectedBorderWidth: 5 }
            }), "ok");
            compare(points(plain.corners), [[40, 0], [200, 0], [160, 100], [0, 100]]);
            compare(points(pathOf(mask(plain)).pathElements[0].path), [[40, 0], [200, 0], [160, 100], [0, 100], [40, 0]]);
            tryCompare(wash(plain), "color", Qt.color("#6bffffff"));
            compare(pathOf(edge(plain)).strokeWidth, 1);
            compare(String(pathOf(edge(plain)).strokeColor), "#bababa");
            compare(pathOf(edge(chosen)).strokeWidth, 5);
            compare(String(pathOf(edge(chosen)).strokeColor), "#0000ff");
            wait(50);
            const img = grabImage(chosen);
            compare([img.red(100, 1), img.green(100, 1), img.blue(100, 1)], [0, 0, 255]);
        }
    }
}
