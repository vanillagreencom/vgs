import QtQuick
import QtTest
import qs.Ui

// SlimScrollBar, the scroll bar a plugin that owns its look draws with its
// own values: it shows only while its flickable overflows, its thumb is the
// view's share of the content and sits as far down as the view, a drag on
// it scrolls the view, and it widens under the pointer.
Item {
    id: root
    width: 200
    height: 300

    readonly property var step: ({ duration: 0, easing: Easing.Linear })

    Flickable {
        id: long
        width: 100
        height: 100
        contentHeight: 400
        Rectangle { width: 100; height: 400; color: "transparent" }
        SlimScrollBar {
            id: bar
            parent: long
            flickable: long
            x: 90
            width: 10
            thin: 2
            wide: 6
            minLength: 20
            color: "white"
            radius: 3
            idleOpacity: 0.2
            movingOpacity: 0.4
            activeOpacity: 0.8
            widthStep: root.step
            opacityStep: root.step
        }
    }

    Flickable {
        id: short
        y: 150
        width: 100
        height: 100
        contentHeight: 60
        SlimScrollBar {
            id: hidden
            parent: short
            flickable: short
            width: 10
            thin: 2
            wide: 6
            minLength: 20
            color: "white"
            radius: 3
            idleOpacity: 0.2
            movingOpacity: 0.4
            activeOpacity: 0.8
            widthStep: root.step
            opacityStep: root.step
        }
    }

    TestCase {
        name: "slimscrollbar"
        when: windowShown

        function init() { long.contentY = 0; }

        function test_it_shows_only_while_the_content_overflows() {
            compare(bar.visible, true);
            compare(hidden.visible, false);
        }

        function test_the_thumb_is_the_view_share_and_follows_the_view() {
            compare(bar.height, 25);
            compare(bar.y, 0);
            long.contentY = 300;
            compare(bar.y, 75);
        }

        function test_a_drag_scrolls_the_view() {
            mousePress(bar, 5, 5);
            mouseMove(bar, 5, 5 + 75 / 2);
            mouseMove(bar, 5, 5 + 75);
            mouseRelease(bar, 5, 5 + 75);
            fuzzyCompare(long.contentY, 300, 1);
        }

        function test_it_widens_under_the_pointer() {
            const thumb = bar.children[0];
            compare(thumb.width, 2);
            mouseMove(bar, 5, 5);
            tryCompare(thumb, "width", 6);
            compare(thumb.opacity, 0.8);
            mouseMove(root, 190, 290);
            tryCompare(thumb, "width", 2);
        }
    }
}
