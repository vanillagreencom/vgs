import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Slider: the handle and the fill follow the value, the right key steps
// it, a click on the track moves it, and a theme change resizes the track.
Item {
    id: root
    width: 300
    height: 100

    Slider { id: slider; from: 0; to: 100; stepSize: 10; value: 50; width: 200 }

    TestCase {
        name: "slider"
        when: windowShown

        function init() { UnitTheme.reset(); slider.value = 50; }

        function fill() { return slider.background.children[0]; }

        function test_handle_and_fill_follow_the_value() {
            fuzzyCompare(slider.visualPosition, 0.5, 0.001);
            fuzzyCompare(fill().width, slider.background.width / 2, 1);
            fuzzyCompare(slider.handle.x, (slider.availableWidth - slider.handle.width) / 2, 1);
            compare(slider.background.height, Theme.slider.track);
            compare(slider.handle.width, Theme.slider.handle);
        }

        function test_right_key_steps() {
            slider.forceActiveFocus();
            keyClick(Qt.Key_Right);
            compare(slider.value, 60);
            keyClick(Qt.Key_Left);
            compare(slider.value, 50);
        }

        function test_click_on_the_track_moves_the_value() {
            mouseClick(slider, slider.width - 1, slider.height / 2);
            verify(slider.value >= 90, "a click at the end moves the value near the end: " + slider.value);
        }

        function test_theme_change_resizes_the_track() {
            compare(UnitTheme.override({ slider: { track: 8, handle: 20, fill: "#00ff00" } }), "ok");
            compare(slider.background.height, 8);
            compare(slider.handle.width, 20);
            compare(String(fill().color), "#00ff00");
        }
    }
}
