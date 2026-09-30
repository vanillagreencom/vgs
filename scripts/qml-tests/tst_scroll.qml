import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The embedded scroll bar ScrollArea and Select draw: it shows only while
// the content overflows, in a gutter a scroll area's content always leaves
// free; its thumb is
// never shorter than `scrollArea.minThumb` and otherwise the view's share
// of the track; dragging the thumb scrolls the content with it and a press
// on the track pages; it shows while hovered or scrolling and fades to
// `scrollArea.idleOpacity` after `scrollArea.fadeDelay`. A select's long
// list leaves the same gutter.
Item {
    id: root
    width: 400
    height: 400
    property real singleFixedHeight: Theme.size.control.lg
    property real brimHeight: 100.3

    ScrollArea { id: area; width: 100; height: 100; Column { width: parent.width; Repeater { model: 10; Rectangle { width: parent.width; height: 20; color: "transparent" } } } }
    ScrollArea { id: short; x: 120; width: 100; height: 100; Column { width: parent.width; Rectangle { width: parent.width; height: 40; color: "transparent" } } }
    ScrollArea { id: brim; x: 360; width: 30; height: 100; Item { width: parent.width; height: root.brimHeight } }
    ScrollArea { id: tall; x: 240; width: 100; height: 100; Column { width: parent.width; Rectangle { width: parent.width; height: 100000; color: "transparent" } } }
    ScrollArea { id: inset; y: 140; width: 120; height: 100; rightInset: Theme.inset.window; Column { width: parent.width; Repeater { model: 10; Rectangle { width: parent.width; height: 20; color: "transparent" } } } }
    ScrollArea { id: singleFixed; x: 140; y: 140; width: 120; height: 100; Item { y: Theme.space.sm; width: parent.width; implicitHeight: root.singleFixedHeight } }
    Item {
        id: hideParent
        x: 280
        y: 140
        width: 100
        height: 100

        ScrollArea {
            id: hiddenArea
            anchors.fill: parent

            Column {
                width: parent.width
                Repeater { model: 10; Rectangle { width: parent.width; height: 20; color: "transparent" } }
            }
        }
    }
    Select { id: long; y: 300; model: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p"] }

    TestCase {
        name: "scroll"
        when: windowShown

        function init() {
            UnitTheme.reset();
            area.contentY = 0;
            area.bar.hovered = false;
            root.singleFixedHeight = Theme.size.control.lg;
            hideParent.visible = true;
            hiddenArea.contentY = 0;
            long.choose(0);
            root.brimHeight = 100.3;
        }

        // Content 0.3 px past the view is float noise of a layout that fits
        // exactly: no bar, no press taken. 0.5 px past it overflows.
        function test_less_than_half_a_pixel_past_the_view_is_no_overflow() {
            compare(brim.overflowing, false);
            compare(brim.bar.visible, false);
            compare(brim.interactive, false);
            root.brimHeight = 100.5;
            compare(brim.overflowing, true);
            compare(brim.bar.visible, true);
            compare(brim.interactive, true);
            compare(area.interactive, true);
            compare(short.interactive, false);
        }

        function test_the_bar_sits_in_a_gutter_the_content_leaves_free() {
            compare(area.overflowing, true);
            compare(area.contentWidth, area.width - Theme.scrollArea.gutter);
            compare(area.bar.visible, true);
            compare(area.bar.x, area.width - Theme.scrollArea.barWidth - Theme.scrollArea.barInset);
            verify(area.bar.x >= area.contentWidth, "the bar starts at " + area.bar.x + ", past the content's " + area.contentWidth);
            compare(short.overflowing, false);
            compare(short.contentWidth, short.width - Theme.scrollArea.gutter, "the gutter stays free without an overflow, so the layout does not move when one starts");
            compare(short.bar.visible, false);
        }

        function test_a_single_direct_child_sets_the_content_height_without_childrenrect() {
            compare(singleFixed.contentWidth, singleFixed.width - Theme.scrollArea.gutter);
            compare(singleFixed.contentHeight, Theme.space.sm + Theme.size.control.lg);
            root.singleFixedHeight = Theme.size.panel.sm;
            compare(singleFixed.contentHeight, Theme.space.sm + Theme.size.panel.sm);
            root.singleFixedHeight = Theme.size.control.md;
            compare(singleFixed.contentHeight, Theme.space.sm + Theme.size.control.md);
        }

        function test_hiding_an_ancestor_keeps_scroll_position_and_content_height() {
            hiddenArea.contentY = 60;
            const beforeY = hiddenArea.contentY;
            const beforeHeight = hiddenArea.contentHeight;
            verify(beforeHeight > hiddenArea.height, "the area overflows before it is hidden");
            hideParent.visible = false;
            compare(hiddenArea.visible, false);
            compare(hiddenArea.contentHeight, beforeHeight);
            compare(hiddenArea.contentY, beforeY);
            hideParent.visible = true;
            compare(hiddenArea.contentHeight, beforeHeight);
            compare(hiddenArea.contentY, beforeY);
        }

        function test_the_bar_can_sit_inside_a_container_inset() {
            compare(inset.contentWidth, inset.width - Theme.inset.window);
            verify(Theme.scrollArea.gutter <= Theme.inset.window, "the default gutter fits in the window inset");
            verify(inset.bar.x >= inset.contentWidth, "bar starts at " + inset.bar.x + ", content ends at " + inset.contentWidth);
            verify(inset.bar.x + inset.bar.width <= inset.width, "bar ends inside the scroll area");
        }

        function test_the_thumb_is_the_view_share_and_never_below_the_minimum() {
            // A 100 px view of 200 px content: half the track.
            compare(area.bar.thumb.height, 50);
            compare(tall.bar.thumb.height, Theme.scrollArea.minThumb);
            tall.contentY = tall.contentHeight - tall.height;
            compare(tall.bar.thumb.y + tall.bar.thumb.height, tall.bar.height);
            tall.contentY = 0;
        }

        function test_dragging_the_thumb_scrolls_the_content() {
            const thumb = area.bar.thumb;
            mousePress(thumb, thumb.width / 2, 5);
            // 25 px of the 50 px travel is half the 100 px the content moves.
            mouseMove(thumb, thumb.width / 2, 30);
            mouseRelease(thumb, thumb.width / 2, 30);
            compare(area.contentY, 50);
            compare(thumb.y, 25);
        }

        function test_a_press_on_the_track_pages() {
            mouseClick(area.bar, area.bar.width / 2, 90);
            compare(area.contentY, 100, "a press under the thumb pages one view down, held at the end");
            mouseClick(area.bar, area.bar.width / 2, 5);
            compare(area.contentY, 0, "a press above the thumb pages one view up");
        }

        function test_the_bar_shows_while_scrolling_or_hovered_and_fades_after() {
            compare(UnitTheme.override({ scrollArea: { fadeDelay: 200, fade: 0, idleOpacity: 0.25 } }), "ok");
            // The pointer rests away from the bar, so only these inputs move it.
            mouseMove(area.bar, area.bar.width / 2, 10);
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(area.bar, "opacity", 0.25);
            area.contentY = 10;
            tryCompare(area.bar, "opacity", 1);
            tryCompare(area.bar, "opacity", 0.25, 2000);
            area.bar.hovered = true;
            tryCompare(area.bar, "opacity", 1);
            area.bar.hovered = false;
            tryCompare(area.bar, "opacity", 0.25);
        }

        function test_a_long_select_list_leaves_the_gutter() {
            long.openList();
            let list = null;
            for (const child of long.resources) if (child.anchor !== undefined) list = child;
            verify(list !== null, "the select holds its list window");
            const view = list.contentItem.children.find(child => child.overflowing !== undefined);
            verify(view !== undefined, "the list holds its view");
            compare(view.overflowing, true);
            const entry = view.itemAtIndex(0);
            compare(entry.width, view.width - Theme.scrollArea.gutter);
            long.choose(0);
        }
    }
}
