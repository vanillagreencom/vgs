import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Scrim: it fills its parent, draws `color.scrim` under the default theme
// and under a light theme, emits `clicked` for a click on it, and takes the
// press, the hover and the wheel, so the button and the scroll area under it
// answer nothing. Each of the last two first shows that the same pointer
// reaches the control once the scrim is hidden. Expected colours are
// worked by hand from the defaults in Tokens.js, never read from Theme.
Item {
    id: root
    width: 300
    height: 200

    Item {
        id: frame
        x: 20; y: 30; width: 240; height: 150

        Button { id: under; text: "Under"; x: 10; y: 10 }
        ScrollArea {
            id: scroller
            x: 130; y: 10; width: 100; height: 100
            Rectangle { width: 100; height: 400; color: "gray" }
        }
        Scrim { id: scrim }
    }
    SignalSpy { id: clicks; target: scrim; signalName: "clicked" }
    SignalSpy { id: underClicks; target: under; signalName: "clicked" }

    TestCase {
        name: "scrim"
        when: windowShown

        function init() {
            UnitTheme.reset();
            clicks.clear();
            underClicks.clear();
            scrim.visible = true;
            scroller.contentY = 0;
            mouseMove(root, root.width - 1, root.height - 1);
        }

        function test_fills_its_parent() {
            compare([scrim.x, scrim.y, scrim.width, scrim.height], [0, 0, 240, 150]);
        }

        // alpha(#000000, 0.6): 0.6 * 255 = 153, 0x99.
        function test_draws_the_scrim_colour() {
            compare(String(scrim.color), "#99000000");
        }

        function test_a_theme_moves_the_colour() {
            compare(UnitTheme.override({ palette: { background: "#ffffff" } }), "ok");
            compare(String(scrim.color), "#99ffffff");
            compare(UnitTheme.override({ color: { scrim: "#11223344" } }), "ok");
            compare(String(scrim.color), "#44112233");
        }

        function test_a_click_is_reported_and_reaches_nothing_under_it() {
            mouseClick(scrim, 200, 120);
            compare(clicks.count, 1);
            mouseClick(scrim, under.x + under.width / 2, under.y + under.height / 2);
            compare(clicks.count, 2);
            compare(underClicks.count, 0);
        }

        function test_hover_reaches_nothing_under_it() {
            scrim.visible = false;
            mouseMove(frame, under.x + under.width / 2, under.y + under.height / 2);
            tryCompare(under, "hovered", true);
            mouseMove(root, root.width - 1, root.height - 1);
            tryCompare(under, "hovered", false);
            scrim.visible = true;
            mouseMove(scrim, under.x + under.width / 2, under.y + under.height / 2);
            wait(50);
            verify(!under.hovered, "the button under the scrim is hovered");
        }

        function test_the_wheel_reaches_nothing_under_it() {
            const x = scroller.x + scroller.width / 2;
            const y = scroller.y + scroller.height / 2;
            scrim.visible = false;
            mouseWheel(frame, x, y, 0, -120);
            tryVerify(() => scroller.contentY > 0, 1000, "the wheel scrolls the area with no scrim");
            scroller.cancelFlick();
            scroller.contentY = 0;
            scrim.visible = true;
            mouseWheel(scrim, x, y, 0, -120);
            wait(50);
            compare(scroller.contentY, 0);
        }
    }
}
