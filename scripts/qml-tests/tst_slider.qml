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
    Slider { id: mirrored; from: 0; to: 100; value: 25; width: 200; y: 40; LayoutMirroring.enabled: true }
    SignalSpy { id: moves; target: slider; signalName: "moved" }

    TestCase {
        name: "slider"
        when: windowShown

        function init() { UnitTheme.reset(); slider.value = 50; slider.pageStep = Qt.binding(() => slider.stepSize > 0 ? slider.stepSize * 5 : Math.abs(slider.to - slider.from) / 20); moves.clear(); }

        function fill() { return slider.background.children[0]; }

        function test_handle_and_fill_follow_the_value() {
            fuzzyCompare(slider.visualPosition, 0.5, 0.001);
            fuzzyCompare(fill().width, slider.background.width / 2, 1);
            fuzzyCompare(slider.handle.x, (slider.availableWidth - slider.handle.width) / 2, 1);
            compare(slider.background.height, Theme.slider.track);
            compare(slider.handle.width, Theme.slider.handle);
        }

        // The thin track keeps a `size.control.sm` input area: a press a
        // few pixels above the track still moves the value.
        function test_the_slider_keeps_an_input_area() {
            compare(slider.height, Theme.size.control.sm);
            verify(slider.background.height < slider.height, "the track is thinner than its input area");
            mouseClick(slider, slider.width - 4, 1);
            verify(slider.value > 50, "a press above the track moves the value: " + slider.value);
            slider.value = 50;
        }

        function test_right_key_steps() {
            slider.forceActiveFocus();
            keyClick(Qt.Key_Right);
            compare(slider.value, 60);
            keyClick(Qt.Key_Left);
            compare(slider.value, 50);
            keyClick(Qt.Key_Up);
            compare(slider.value, 60);
            compare(moves.count, 3);
            keyClick(Qt.Key_Down);
            compare(slider.value, 50);
            compare(moves.count, 4);
            keyClick(Qt.Key_Home);
            compare(slider.value, 0);
            compare(moves.count, 5);
            keyClick(Qt.Key_End);
            compare(slider.value, 100);
            compare(moves.count, 6);
            slider.value = 50;
            slider.pageStep = 25;
            keyClick(Qt.Key_PageUp);
            compare(slider.value, 80);
            keyClick(Qt.Key_PageDown);
            compare(slider.value, 60);
            compare(moves.count, 8);
        }

        function test_click_on_the_track_moves_the_value() {
            mouseClick(slider, slider.width - 1, slider.height / 2);
            verify(slider.value >= 90, "a click at the end moves the value near the end: " + slider.value);
        }

        function test_mirrored_fill_starts_from_the_right() {
            const fillItem = mirrored.background.children[0];
            fuzzyCompare(fillItem.width, mirrored.background.width / 4, 1);
            fuzzyCompare(fillItem.x + fillItem.width, mirrored.background.width, 1);
            mirrored.value = 0;
            fuzzyCompare(fillItem.width, 0, 1);
            mirrored.value = 100;
            fuzzyCompare(fillItem.width, mirrored.background.width, 1);
            fuzzyCompare(fillItem.x, 0, 1);
            mirrored.value = 25;
        }

        function test_theme_change_resizes_the_track() {
            compare(UnitTheme.override({ slider: { track: 8, handle: 20, fill: "#00ff00" } }), "ok");
            compare(slider.background.height, 8);
            compare(slider.handle.width, 20);
            compare(String(fill().color), "#00ff00");
        }
    }
}
