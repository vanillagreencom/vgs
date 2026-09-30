import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// ListCursor, ListEntrance and a ListItem that names a cursor: the cursor
// travels to the highlighted row and takes its height over motion.list,
// lands at once at motion.scale 0, after snap() and where it appears, keeps
// travelling when a row lets go before the next row takes it, fades out
// when no row holds it, and follows a row through the items between; a
// hover moves the selection only once the pointer moved since the cursor
// was disarmed; a row in a cursor list draws no fill of its own and enters
// staggered, and stands in place at once while motion is stilled; a
// plugin's own background and bezier step are taken.
Item {
    id: root
    width: 400
    height: 600

    property int current: 0
    property int count: 4

    Item {
        id: holder
        width: 300
        height: 400

        ListCursor { id: plate }

        Column {
            id: rows
            y: 20
            width: parent.width
            Repeater {
                id: repeater
                model: root.count
                ListItem {
                    required property int index
                    width: rows.width
                    text: "Row " + index
                    // Every other row carries a secondary line, so the rows
                    // differ in height and the cursor must resize.
                    secondary: index % 2 === 1 ? "detail" : ""
                    cursor: plate
                    highlighted: index === root.current
                    onPointed: root.current = index
                }
            }
        }
    }

    ListItem { id: loose; text: "Loose"; width: 300; y: 500 }

    Item {
        id: other
        y: 540
        width: 300
        height: 40
        ListCursor {
            id: owned
            motion: ({
                travel: { duration: 400, easing: Easing.BezierSpline, curve: [0.05, 0.7, 0.1, 1, 1, 1] },
                resize: { duration: 400, easing: Easing.BezierSpline, curve: [0.2, 0, 0, 1, 1, 1] },
                fade: { duration: 200, easing: Easing.OutCubic },
                enter: { duration: 300, easing: Easing.OutCubic },
                stagger: 18,
                staggerRows: 8,
                rise: 6
            })
            background: Item { id: ownPlate }
        }
        Item { id: ownRow; width: 300; height: 30 }
    }

    // A surface that paints a fill, with the rows and their cursor in an
    // item inside it, as the launcher's flyout holds them: the plate draws
    // over the fill and under the row's content.
    Rectangle {
        id: painted
        x: 320
        width: 60
        height: 80
        color: "#ff0000"
        Item {
            anchors.fill: parent
            ListCursor { id: paintedPlate; background: Rectangle { color: "#0000ff" } }
            Item {
                id: paintedRow
                y: 20
                width: 60
                height: 30
                Rectangle { width: 20; height: 30; color: "#00ff00" }
            }
        }
    }

    SignalSpy { id: pointed; signalName: "pointed" }

    TestCase {
        name: "listcursor"
        when: windowShown

        function init() {
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            // A row that took the cursor by hand gives it back to the
            // highlighted row.
            root.current = -1;
            root.current = 0;
            rows.y = 20;
            plate.disarm();
            pointed.clear();
            tryVerify(() => plate.target === repeater.itemAt(0), 1000, "the highlighted row holds the cursor");
            tryCompare(plate, "y", 20);
        }

        function cleanupTestCase() { UnitTheme.reset(); }

        function row(index) { return repeater.itemAt(index); }

        function test_the_cursor_travels_to_the_highlighted_row() {
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 }, resize: { duration: 2000 } } } }), "ok");
            const from = plate.y;
            const to = rows.y + row(1).y;
            root.current = 1;
            verify(plate.target === row(1), "the second row holds the cursor");
            wait(100);
            verify(plate.y > from && plate.y < to, "the cursor is between the rows, at " + plate.y + " of " + from + " to " + to);
            verify(plate.height > row(0).height && plate.height < row(1).height, "the cursor is resizing, " + plate.height);
            tryCompare(plate, "y", to, 3000);
            tryCompare(plate, "height", row(1).height, 3000);
            compare(plate.width, row(1).width);
            compare(plate.opacity, 1);
        }

        function test_motion_scale_zero_lands_at_once() {
            root.current = 3;
            compare(plate.y, rows.y + row(3).y);
            compare(plate.height, row(3).height);
        }

        function test_snap_lands_at_once() {
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 } } } }), "ok");
            plate.snap();
            root.current = 2;
            compare(plate.y, rows.y + row(2).y);
            // The snap lasts its turn; the next move travels.
            wait(20);
            root.current = 3;
            verify(plate.y < rows.y + row(3).y, "the cursor travels after the snap's turn, at " + plate.y);
        }

        // Row 0 lets go before row 1 takes it, within one turn: the cursor
        // travels and never fades.
        function test_a_release_before_the_next_claim_keeps_travelling() {
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 }, fade: { duration: 2000 } } } }), "ok");
            plate.follow(row(0), false);
            plate.follow(row(1), true);
            wait(100);
            verify(plate.target === row(1), "the second row holds the cursor");
            compare(plate.opacity, 1);
            verify(plate.y < rows.y + row(1).y, "the cursor travels, at " + plate.y);
        }

        function test_the_cursor_fades_out_and_appears_where_it_lands() {
            root.current = -1;
            tryVerify(() => plate.target === null, 1000, "no row holds the cursor");
            compare(plate.opacity, 0);
            compare(plate.visible, false, "a faded cursor takes no room");
            compare(UnitTheme.override({ motion: { list: { travel: { duration: 2000 }, fade: { duration: 2000 } } } }), "ok");
            root.current = 3;
            compare(plate.y, rows.y + row(3).y, "the cursor lands where it appears");
            wait(100);
            verify(plate.opacity > 0 && plate.opacity < 1, "the cursor fades in, " + plate.opacity);
        }

        function test_the_cursor_follows_the_row_through_the_items_between() {
            rows.y = 60;
            compare(plate.y, 60);
            root.current = 1;
            compare(plate.y, 60 + row(1).y);
        }

        // expected-log: is not inside the cursor's parent -- the planted row sits outside the cursor's parent
        function test_a_row_outside_the_cursor_is_refused() {
            plate.follow(loose, true);
            verify(plate.target === row(0), "the cursor keeps its row");
            compare(plate.y, 20, "the cursor stays where it was");
        }

        function test_a_hover_moves_the_selection_only_after_the_pointer_moved() {
            pointed.target = row(2);
            mouseMove(row(2), 20, 10);
            compare(root.current, 0, "the first reading after a disarm moves nothing");
            compare(plate.armed, false);
            mouseMove(row(2), 20, 10);
            compare(root.current, 0, "a still pointer moves nothing");
            mouseMove(row(2), 22, 10);
            compare(root.current, 2, "a moved pointer takes the selection");
            compare(plate.armed, true);
            compare(pointed.count, 1);
            plate.disarm();
            root.current = 0;
            // The pointer rests where it was, as Qt delivers it hover again
            // while the cursor travels.
            mouseMove(row(2), 22, 10);
            compare(root.current, 0, "a disarmed cursor waits for the pointer to move again");
            // Nothing moves under the pointer here, so Qt delivers no hover
            // between the disarm and the reading: only arm() lets it take.
            plate.disarm();
            plate.arm();
            mouseMove(row(2), 24, 10);
            compare(root.current, 2, "an armed cursor takes the selection on its first reading");
            mouseMove(root, 390, 590);
        }

        function test_a_row_with_a_cursor_draws_no_fill() {
            compare(String(row(0).background.color), "#00000000");
            loose.highlighted = true;
            tryCompare(loose.background, "color", Qt.color(Theme.listItem.selected));
            loose.highlighted = false;
            compare(String(plate.background.color), String(Qt.color(Theme.listItem.selected)));
            compare(plate.background.parent, plate);
            compare(plate.background.width, plate.width);
        }

        // The plate draws the pressed fill while the row it holds is
        // pressed, and its resting fill again after a release outside the
        // row; a loose row draws its own pressed fill, apart from hover.
        function test_a_pressed_row_presses_the_plate() {
            root.current = 0;
            tryCompare(plate, "target", row(0));
            mousePress(row(0), 20, row(0).height / 2);
            tryCompare(plate, "pressed", true);
            compare(String(plate.background.color), String(Qt.color(Theme.listItem.selectedPressed)));
            mouseMove(root, root.width - 2, root.height - 2);
            mouseRelease(root, root.width - 2, root.height - 2);
            tryCompare(plate, "pressed", false);
            compare(String(plate.background.color), String(Qt.color(Theme.listItem.selected)));
            mouseMove(loose, 20, loose.height / 2);
            tryCompare(loose.background, "color", Qt.color(Theme.listItem.hover));
            mousePress(loose, 20, loose.height / 2);
            tryCompare(loose.background, "color", Qt.color(Theme.listItem.pressed));
            mouseRelease(loose, 20, loose.height / 2);
            loose.highlighted = true;
            mousePress(loose, 20, loose.height / 2);
            tryCompare(loose.background, "color", Qt.color(Theme.listItem.selectedPressed));
            mouseRelease(loose, 20, loose.height / 2);
            loose.highlighted = false;
            mouseMove(root, root.width - 2, root.height - 2);
        }

        function test_rows_enter_staggered() {
            compare(UnitTheme.override({ motion: { list: { enter: { duration: 2000 }, stagger: 400 } } }), "ok");
            root.count = 0;
            root.count = 4;
            const first = row(0).transform[0];
            const last = row(3).transform[0];
            compare(first.progress, 0);
            compare(first.y, Theme.motion.list.rise);
            compare(last.run.delay, 3 * 400);
            wait(300);
            verify(first.progress > 0, "the first row enters at once, " + first.progress);
            compare(last.progress, 0, "the fourth row waits its turn");
            verify(row(0).opacity > 0 && row(0).opacity < 1, "the row's opacity follows its entrance, " + row(0).opacity);
            root.count = 0;
            root.count = 4;
            compare(row(0).transform[0].run.delay, 0, "a later turn's first row enters at once");
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            root.count = 0;
            root.count = 4;
            compare(row(0).transform[0].progress, 1, "a stilled entrance stands the row in place");
            compare(row(3).opacity, 1);
        }

        function test_an_entrance_slides_from_its_side() {
            const entrance = Qt.createQmlObject("import qs.Ui\nListEntrance { shift: 18 }", root);
            compare(UnitTheme.override({ motion: { list: { enter: { duration: 2000 } } } }), "ok");
            entrance.start(0, -1);
            compare(entrance.x, -18);
            compare(entrance.y, 0);
            entrance.destroy();
        }

        // expected-log: paints a fill over the plate -- the planted cursor sits directly in a surface that paints
        function test_a_cursor_in_a_painting_parent_is_refused() {
            const direct = Qt.createQmlObject("import qs.Ui\nListCursor {}", painted);
            direct.destroy();
        }

        function test_the_plate_draws_over_the_surface_and_under_the_rows() {
            paintedPlate.follow(paintedRow, true);
            tryCompare(paintedPlate, "opacity", 1);
            const image = grabImage(painted);
            verify(Qt.colorEqual(image.pixel(40, 35), "#0000ff"), "the plate draws over the parent's fill, got " + image.pixel(40, 35));
            verify(Qt.colorEqual(image.pixel(10, 35), "#00ff00"), "the row's content draws over the plate, got " + image.pixel(10, 35));
            verify(Qt.colorEqual(image.pixel(40, 5), "#ff0000"), "the parent's fill shows around the plate, got " + image.pixel(40, 5));
        }

        function test_a_plugin_look_brings_its_background_and_bezier_steps() {
            compare(ownPlate.parent, owned);
            owned.follow(ownRow, true);
            compare(ownPlate.height, 30);
            compare(owned.shown, true);
            // The first claim lands at once for the rest of its turn.
            wait(50);
            ownRow.y = 100;
            wait(100);
            // A quarter of the way, the plugin's decelerating curve is past
            // 60 of the 100 pixels, where a linear one is near 25.
            verify(owned.y > 60 && owned.y < 100, "the plugin's own curve travels, at " + owned.y);
            tryCompare(owned, "y", 100, 1000);
        }
    }
}
