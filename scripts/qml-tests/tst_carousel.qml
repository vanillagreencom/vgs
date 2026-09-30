import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// CardCarousel: the rail's geometry at the reference size, at a size its
// height limits and at one its width limits, and the unit held at both
// ends of its range; the slices shown and the cards built, at two sizes
// and after a step; the decode size each card's content is handed; the
// click that selects, the click that activates and the parallelogram each
// click and hover lands in; the height the width asks for; the keys and the wheel; the rail held hidden until it
// settles; the motion, over the duration and stilled at motion.scale 0; a
// glide that keeps the cards it leaves and builds the ones it reaches, a
// wrap that lands at once, and the clip at the carousel's edge; and a
// delegate that cannot build, named and left empty. Expected values are worked by hand from the defaults in Tokens.js:
// a 768 by 476 expanded card, 108 by 432 slices overlapping by the 28
// pixel lean, so a slice step of 80, and a reference rail of 768 + 13 * 80
// + 2 * 20 = 1848.
Item {
    id: root
    width: 2100
    height: 600

    readonly property var entries: Array.from({ length: 60 }, (_, i) => "e" + i)

    Component {
        id: content
        Rectangle {
            required property var modelData
            required property size decodeSize
            anchors.fill: parent
            color: "white"
        }
    }
    Component {
        id: currentContent
        Rectangle {
            required property var modelData
            required property size decodeSize
            property bool current: false
            anchors.fill: parent
            color: current ? "white" : "black"
        }
    }
    // Delegates that cannot build a card: one without decodeSize, and one
    // that declares a required property the carousel does not hand over.
    Component {
        id: missingSize
        Rectangle {
            objectName: "broken"
            required property var modelData
        }
    }
    Component {
        id: extraRequired
        Rectangle {
            objectName: "broken"
            required property var modelData
            required property size decodeSize
            required property int extra
        }
    }
    Component {
        id: small
        CardCarousel { width: 600; height: 200; model: 3 }
    }

    Rectangle { anchors.fill: parent; color: "black" }
    ListModel { id: changingModel }
    CardCarousel {
        id: carousel
        x: 100
        model: root.entries
        delegate: content
    }
    SignalSpy { id: activations; target: carousel; signalName: "activated" }

    TestCase {
        name: "carousel"
        when: windowShown

        function init() {
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            // Hidden and shown again, the carousel drops a part-notch a
            // test left and settles afresh.
            carousel.visible = false;
            carousel.visible = true;
            carousel.width = 1848;
            carousel.height = 476;
            carousel.devicePixelRatio = 1;
            carousel.delegate = content;
            carousel.model = root.entries;
            carousel.currentIndex = 20;
            carousel.forceActiveFocus();
            activations.clear();
            tryVerify(() => rail(carousel).visible, 1000, "the rail settles");
        }

        function cleanupTestCase() { UnitTheme.reset(); }

        function rail(c) { return c.children.find(child => String(child).startsWith("QQuickItem(")); }
        function slots(c) { return rail(c).children.filter(child => child.offset !== undefined); }
        function slot(index) { return slots(carousel).find(s => s.index === index); }
        function card(index) { return slot(index).children[0].item.children[0]; }
        function box(index) { const s = slot(index); return [s.x, s.y, s.width, s.height]; }
        function shown() { return slots(carousel).filter(s => s.visible).map(s => s.index); }
        function find(item, test) {
            if (test(item)) return item;
            for (const child of item.children) {
                const found = find(child, test);
                if (found !== null) return found;
            }
            return null;
        }
        // The content each built card holds, by its entry.
        function built() {
            const out = {};
            for (const s of slots(carousel)) {
                const found = s.children[0].item ? find(s.children[0].item, item => item.decodeSize !== undefined) : null;
                if (found !== null) out[found.modelData] = found;
            }
            return out;
        }
        function builtNames() { return Object.keys(built()).sort((a, b) => a.slice(1) - b.slice(1)); }
        function range(from, to) { return Array.from({ length: to - from + 1 }, (_, i) => "e" + (from + i)); }
        function indices(from, to) { return Array.from({ length: to - from + 1 }, (_, i) => from + i); }

        // Unit 1: the expanded card at (1848 - 768) / 2 = 540, the slices
        // 22 down, the first right slice 28 over the card at 1280. Six
        // slices fit whole a side, 6 * 80 = 480 <= 540; built are two more.
        function test_geometry_at_the_reference_size() {
            compare(box(20), [540, 0, 768, 476]);
            compare(box(19), [460, 22, 108, 432]);
            compare(box(14), [60, 22, 108, 432]);
            compare(box(21), [1280, 22, 108, 432]);
            compare(box(22), [1360, 22, 108, 432]);
            compare(box(26), [1680, 22, 108, 432]);
            compare(card(20).skew, 28);
            compare(shown(), indices(14, 26));
            tryVerify(() => builtNames().length === 17);
            compare(builtNames(), range(12, 28));
        }

        // 2000 by 238: 238 / 476 = 0.5 is under 2000 / 1848. The card is
        // 384 by 238 at (2000 - 384) / 2 = 808, slices 54 by 216 at
        // (238 - 216) / 2 = 11, a step of 40; floor(808 / 40) = 20 slices a
        // side, 22 built.
        function test_geometry_where_the_height_limits() {
            carousel.width = 2000;
            carousel.height = 238;
            carousel.currentIndex = 30;
            compare(box(30), [808, 0, 384, 238]);
            compare(box(29), [768, 11, 54, 216]);
            compare(box(31), [1178, 11, 54, 216]);
            compare(box(32), [1218, 11, 54, 216]);
            compare(card(30).skew, 14);
            compare(shown(), indices(10, 50));
            tryVerify(() => builtNames().length === 45);
            compare(builtNames(), range(8, 52));
        }

        // 924 by 476: 924 / 1848 = 0.5. The card at (924 - 384) / 2 = 270
        // and (476 - 238) / 2 = 119; floor(270 / 40) = 6 a side.
        function test_geometry_where_the_width_limits() {
            carousel.width = 924;
            compare(box(20), [270, 119, 384, 238]);
            compare(box(19), [230, 130, 54, 216]);
            compare(box(21), [640, 130, 54, 216]);
            compare(shown(), indices(14, 26));
        }

        // 400 by 100 asks 100 / 476 = 0.21, held at 0.35: 768 * 0.35 =
        // 268.8, 476 * 0.35 = 166.6. 4000 by 1000 asks 1000 / 476 = 2.1,
        // held at 2.
        function test_the_unit_is_held_in_its_range() {
            carousel.width = 400;
            carousel.height = 100;
            fuzzyCompare(slot(20).width, 268.8, 1e-9);
            fuzzyCompare(slot(20).height, 166.6, 1e-9);
            carousel.width = 4000;
            carousel.height = 1000;
            compare([slot(20).width, slot(20).height], [1536, 952]);
        }

        // The height the width asks for, whatever the height: 476 at the
        // reference width, 476 * 924 / 1848 = 238 at half of it, and the
        // unit held at 0.35, 166.6, and at 2, 952.
        function test_the_width_asks_for_a_height() {
            compare(carousel.implicitHeight, 476);
            carousel.height = 100;
            compare(carousel.implicitHeight, 476);
            carousel.width = 924;
            compare(carousel.implicitHeight, 238);
            carousel.width = 400;
            fuzzyCompare(carousel.implicitHeight, 166.6, 1e-9);
            carousel.width = 4000;
            compare(carousel.implicitHeight, 952);
        }

        function test_a_step_moves_the_band() {
            keyClick(Qt.Key_Right);
            compare(shown(), indices(15, 27));
            tryVerify(() => builtNames()[0] === "e13");
            compare(builtNames(), range(13, 29));
            compare(card(21).selected, true);
            compare(card(20).selected, false);
        }

        // At unit 1 and two device pixels a pixel: a slice decodes at 216
        // by 864, the current card and its neighbours at 1536 by 952. At
        // four, 3072 by 1904 is still under the 4096-pixel long-side cap.
        // At six, 4608 by 2856 is held to 4096 on the longer side: 2856 *
        // 4096 / 4608 = 2538.7.
        function test_each_card_is_handed_its_decode_size() {
            carousel.devicePixelRatio = 2;
            compare(built().e20.decodeSize, Qt.size(1536, 952));
            compare(built().e19.decodeSize, Qt.size(1536, 952));
            compare(built().e21.decodeSize, Qt.size(1536, 952));
            compare(built().e22.decodeSize, Qt.size(216, 864));
            compare(built().e18.decodeSize, Qt.size(216, 864));
            keyClick(Qt.Key_Right);
            compare(built().e22.decodeSize, Qt.size(1536, 952));
            compare(built().e19.decodeSize, Qt.size(216, 864));
            carousel.devicePixelRatio = 4;
            compare(built().e21.decodeSize, Qt.size(3072, 1904));
            compare(built().e23.decodeSize, Qt.size(432, 1728));
            carousel.devicePixelRatio = 6;
            compare(built().e21.decodeSize, Qt.size(4096, 2539));
        }

        function test_a_delegate_can_read_whether_it_is_current() {
            carousel.delegate = currentContent;
            carousel.model = 0;
            wait(0);
            carousel.model = root.entries;
            carousel.currentIndex = 20;
            tryVerify(() => builtNames().length === 17);
            compare(built().e20.current, true);
            compare(built().e19.current, false);
            keyClick(Qt.Key_Right);
            compare(built().e21.current, true);
            compare(built().e20.current, false);
            carousel.delegate = content;
            carousel.model = root.entries;
        }

        function test_a_model_change_rebinds_built_card_content() {
            changingModel.clear();
            for (let i = 0; i < 60; i++) changingModel.append({ modelData: "e" + i });
            carousel.model = changingModel;
            carousel.currentIndex = 20;
            tryVerify(() => built().e20 !== undefined);
            compare(built().e20.modelData, "e20");
            changingModel.setProperty(20, "modelData", "replacement");
            tryVerify(() => built().replacement !== undefined);
            compare(built().replacement.modelData, "replacement");
            verify(built().e20 === undefined);
        }

        function test_a_click_selects_a_slice_and_activates_the_current_card() {
            mouseClick(carousel, 1397, 238);
            compare(carousel.currentIndex, 22);
            compare(activations.count, 0);
            mouseClick(carousel, 911, 238);
            compare(carousel.currentIndex, 22);
            compare(activations.count, 1);
            compare(activations.signalArguments[0][0], 22);
        }

        // Card 21 spans 1280 to 1388 and card 22 1360 to 1468, and card 21
        // is drawn over card 22. The overlap is the lean, so the two share
        // one edge: 420 down the slices, at 442, it is at 1360 + 28 * 12 /
        // 432 = 1360.8, so x 1365 is inside card 22 alone though card 21's
        // box holds it; halfway down, at 238, it is at 1374, so x 1370 is
        // inside card 21 alone though card 22's box holds it.
        function test_a_click_lands_in_the_parallelogram_that_holds_it() {
            mouseClick(carousel, 1365, 442);
            compare(carousel.currentIndex, 22);
            carousel.currentIndex = 20;
            mouseClick(carousel, 1370, 238);
            compare(carousel.currentIndex, 21);
        }

        // The pointer at those two points is over card 22 and then card 21
        // alone, by the same parallelograms, and over no card off the rail.
        function test_the_pointer_hovers_the_card_that_holds_it() {
            mouseMove(carousel, 1365, 442);
            tryVerify(() => card(22).hovered, 1000, "card 22 is hovered");
            verify(!card(21).hovered, "card 21 is not hovered through its box");
            mouseMove(carousel, 1370, 238);
            tryVerify(() => card(21).hovered, 1000, "card 21 is hovered");
            verify(!card(22).hovered, "card 22 is not hovered through its box");
            mouseMove(carousel, 5, 5);
            tryVerify(() => !card(21).hovered && !card(22).hovered, 1000, "no card is hovered off the rail");
        }

        function test_the_keys_step_and_wrap() {
            const keys = [
                [Qt.Key_Right, Qt.NoModifier, 21],
                [Qt.Key_Tab, Qt.NoModifier, 22],
                [Qt.Key_Left, Qt.NoModifier, 21],
                [Qt.Key_Backtab, Qt.ShiftModifier, 20],
                [Qt.Key_Tab, Qt.ShiftModifier, 19],
                [Qt.Key_Home, Qt.NoModifier, 0],
                [Qt.Key_Left, Qt.NoModifier, 59],
                [Qt.Key_Right, Qt.NoModifier, 0],
                [Qt.Key_End, Qt.NoModifier, 59]
            ];
            for (const [key, modifiers, want] of keys) {
                keyClick(key, modifiers);
                compare(carousel.currentIndex, want, "key " + key + " with " + modifiers);
            }
            verify(carousel.activeFocus, "Tab stays in the carousel");
        }

        function test_the_wheel_steps_by_the_notch() {
            const wheel = [
                [0, -120, 21],
                [0, 240, 19],
                [0, -60, 19],
                [0, -60, 20],
                [-120, 0, 21]
            ];
            for (const [dx, dy, want] of wheel) {
                mouseWheel(carousel, 5, 5, dx, dy);
                compare(carousel.currentIndex, want, "wheel " + dx + "," + dy);
            }
        }

        function test_a_hidden_carousel_drops_a_part_notch() {
            mouseWheel(carousel, 5, 5, 0, -60);
            carousel.visible = false;
            carousel.visible = true;
            mouseWheel(carousel, 5, 5, 0, -60);
            compare(carousel.currentIndex, 20);
        }

        // A carousel seeded in the turn it is built shows nothing until
        // the next turn, then shows the seeded layout at once.
        function test_the_rail_shows_settled() {
            compare(UnitTheme.override({ carousel: { duration: 2000 } }), "ok");
            const made = Qt.createQmlObject("import qs.Ui\nCardCarousel { width: 1848; height: 476; model: 60 }", root, "made");
            made.currentIndex = 3;
            verify(!rail(made).visible, "the rail is hidden before it settles");
            tryVerify(() => rail(made).visible, 1000, "the rail settles");
            const current = slots(made).find(s => s.index === 3);
            compare(current.x, 540);
            made.visible = false;
            made.visible = true;
            verify(!rail(made).visible, "a carousel shown again settles afresh");
            tryVerify(() => rail(made).visible, 1000, "the rail settles again");
            made.destroy();
        }

        // Unit 1: card 21 starts 28 over card 20's right edge, at 1280.
        function test_the_rail_moves_over_the_duration() {
            compare(UnitTheme.override({ carousel: { duration: 2000 } }), "ok");
            keyClick(Qt.Key_Right);
            wait(300);
            const x = slot(21).x;
            verify(x < 1280 && x > 540, "card 21 is on its way at " + x);
            tryCompare(slot(21), "x", 540, 5000);
        }

        // A carousel declared at index 30 is built around it.
        function test_a_declared_index_builds_around_itself() {
            const made = Qt.createQmlObject("import qs.Ui\nCardCarousel { width: 1848; height: 476; model: 60; currentIndex: 30 }", root, "declared");
            compare(slots(made).filter(s => s.children[0].item !== null).map(s => s.index), indices(22, 38));
            tryVerify(() => rail(made).visible, 1000, "the rail settles");
            compare(slots(made).find(s => s.index === 30).x, 540);
            made.destroy();
        }

        // A move past the shown slices lands in the same turn: End from 20,
        // then Right from 59 wrapping to 0; the cards around the new index
        // are shown and built and the one left behind is not.
        function test_a_far_move_lands_at_once() {
            compare(UnitTheme.override({ carousel: { duration: 2000 } }), "ok");
            keyClick(Qt.Key_End);
            compare(box(59), [540, 0, 768, 476]);
            compare(shown(), indices(53, 59));
            keyClick(Qt.Key_Right);
            compare(box(0), [540, 0, 768, 476]);
            compare(box(1), [1280, 22, 108, 432]);
            compare(shown(), indices(0, 6));
            compare(builtNames().slice(0, 9), range(0, 8));
            verify(!slot(59).visible, "the card left behind is hidden");
        }

        // 300 ms into a 2000 ms outCubic glide from 20 to 21 the rail is
        // drawn at 20 + 1 - 0.85^3 = 20.39: card 14 is 6.39 from it and
        // still shown, card 12 8.39 and still built, though each is past
        // the shown slices and the band of 21.
        function test_a_near_move_glides_and_keeps_its_cards() {
            compare(UnitTheme.override({ carousel: { duration: 2000 } }), "ok");
            keyClick(Qt.Key_Right);
            wait(300);
            verify(slot(21).x > 540 && slot(21).x < 1280, "card 21 is between its places at " + slot(21).x);
            verify(slot(20).x > 460 && slot(20).x < 540, "card 20 is between its places at " + slot(20).x);
            verify(slot(20).visible && slot(21).visible, "the outgoing and incoming cards are drawn");
            verify(slot(14).visible, "the edge card the rail leaves is drawn");
            const names = builtNames();
            for (const name of ["e12", "e20", "e21", "e29"])
                verify(names.indexOf(name) !== -1, name + " is built mid-glide");
        }

        // Card 27 comes in from 1280 + 6 * 80 = 1760, past the carousel's
        // 1848 right edge by 20 at the start of a glide, 100 to 1948 in the
        // window. Its outline draws there without the clip.
        function test_the_rail_clips_to_the_carousel() {
            compare(UnitTheme.override({ carousel: { duration: 10000 } }), "ok");
            keyClick(Qt.Key_Right);
            wait(50);
            verify(slot(27).visible && slot(27).x + slot(27).width > 1848, "card 27 reaches past the edge at " + slot(27).x);
            const img = grabImage(root);
            let lit = 0;
            for (let x = carousel.x + carousel.width + 1; x < carousel.x + carousel.width + 16; x++)
                for (let y = 0; y < carousel.height; y++)
                    if (img.red(x, y) + img.green(x, y) + img.blue(x, y) > 0) lit++;
            compare(lit, 0);
        }

        // Each broken card is named once and left empty, and the carousel
        // still steps.
        // expected-log: Setting initial properties failed: Rectangle does not have a property called decodeSize -- missingSize takes no decodeSize, on purpose
        // expected-log: Required property extra was not initialized -- extraRequired requires a property the carousel never sets, on purpose
        function test_a_delegate_that_cannot_build_leaves_its_card_empty() {
            for (const broken of [missingSize, extraRequired]) {
                for (let i = 0; i < 3; i++)
                    ignoreWarning(new RegExp("^CardCarousel: no content index=" + i + ";"));
                const made = small.createObject(root, { delegate: broken });
                tryVerify(() => rail(made).visible, 1000, "the rail settles");
                compare(slots(made).filter(s => s.children[0].item !== null).length, 3);
                tryVerify(() => slots(made).every(s => find(s, item => item.objectName === "broken") === null), 1000, "no broken content is left");
                made.forceActiveFocus();
                keyClick(Qt.Key_Right);
                compare(made.currentIndex, 1);
                made.destroy();
            }
        }

        function test_motion_scale_zero_moves_at_once() {
            keyClick(Qt.Key_Right);
            compare(slot(21).x, 540);
            compare(slot(20).x, 460);
        }

        // Expanded 600 wide and overlapping by 40: a reference of 600 + 13
        // * 68 + 40 = 1524, so the unit stays 1 by height; the card at
        // (1848 - 600) / 2 = 624, floor(624 / 68) = 9 slices a side and one
        // more built.
        function test_a_theme_moves_the_rail() {
            compare(UnitTheme.override({ motion: { scale: 0 }, carousel: { expandedWidth: 600, overlap: 40, band: 1 } }), "ok");
            compare(box(20), [624, 0, 600, 476]);
            compare(box(21), [1184, 22, 108, 432]);
            compare(shown(), indices(11, 29));
            tryVerify(() => builtNames().length === 21);
            // Overlapping by 40 past the 28 pixel lean, card 21 at 1184 and
            // card 22 at 1252 share 1266 to 1278 halfway down, where the
            // nearer card, 21, is drawn on top and takes the click.
            mouseClick(carousel, 1272, 238);
            compare(carousel.currentIndex, 21);
        }
    }
}
