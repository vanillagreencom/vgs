import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Scrim: it fills its parent, draws `color.scrim` under the default theme
// and under a light theme, emits `clicked` for a click on it, and takes the
// press, so the button under it answers nothing. Expected colours are
// worked by hand from the defaults in Tokens.js, never read from Theme.
Item {
    id: root
    width: 300
    height: 200

    Item {
        id: frame
        x: 20; y: 30; width: 240; height: 150

        Button { id: under; text: "Under"; x: 10; y: 10 }
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
    }
}
