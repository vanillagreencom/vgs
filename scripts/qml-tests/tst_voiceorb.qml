import QtQuick
import QtQuick.Window
import QtTest
import qs.Ui
import qs.Commons
import qs.Unit

// Properties and animation lifetime only. The offscreen software renderer
// does not draw ShaderEffect; compiled rendering belongs to the smoke row.
Item {
    id: root
    width: 300
    height: 200
    MouseArea { id: underlying; anchors.fill: parent }
    Item {
        id: holder
        anchors.fill: parent
        VoiceOrb { id: orb }
    }
    Window {
        id: otherWindow
        visible: true
        width: 100
        height: 100
        VoiceOrb { id: otherOrb; active: true }
    }
    Label { id: label; text: "Waiting" }

    TestCase {
        name: "voiceorb"
        when: windowShown

        function shader(item) { return item.children.find(child => child instanceof ShaderEffect); }
        function driver(item) { return Array.from(item.resources).find(child => String(child).startsWith("QQuickFrameAnimation")); }
        SignalSpy { id: ticks; signalName: "triggered" }
        SignalSpy { id: otherTicks; signalName: "triggered" }
        SignalSpy { id: presses; target: underlying; signalName: "clicked" }

        function initTestCase() {
            ticks.target = driver(orb);
            otherTicks.target = driver(otherOrb);
        }

        function init() {
            UnitTheme.reset();
            holder.visible = true;
            orb.visible = true;
            orb.active = false;
            orb.tone = "accent";
            orb.level = 0;
            orb.secondaryLevel = 0;
            otherWindow.visible = true;
            ticks.clear();
            otherTicks.clear();
        }

        function still(item, spy) {
            compare(driver(item).running, false);
            const count = spy.count;
            const phase = shader(item).phase;
            // Let real animation frames pass to detect a driver left running.
            wait(100);
            compare(spy.count, count, "no triggered signals while stopped");
            compare(shader(item).phase, phase, "phase remains still");
        }

        function test_defaults_and_tokens() {
            compare(orb.tone, "accent");
            compare(orb.level, 0);
            compare(orb.secondaryLevel, 0);
            compare(orb.active, false);
            compare(orb.width, Theme.voiceOrb.size);
            compare(orb.height, Theme.voiceOrb.size);
            compare(orb.Accessible.ignored, true);
            compare(orb.activeFocusOnTab, false);
            verify(String(shader(orb).fragmentShader).endsWith("/shaders/voiceorb.frag.qsb"));
            compare(UnitTheme.override({ voiceOrb: { size: 120, radius: 0.25, gap: 0.05, stroke: 2, arcStroke: 1, amplitude: 0.03, waveCount: 4, arcSpan: 3, arcOpacity: 0.4 } }), "ok");
            compare(orb.width, 120);
            compare(orb.height, 120);
            compare(shader(orb).dimensions, Qt.vector2d(120, 120));
            compare(shader(orb).lines, Qt.vector4d(0.25, 0.05, 2, 1));
            compare(shader(orb).waves, Qt.vector4d(0.03, 4, 3, 0.4));
        }

        function test_passes_pointer_input_through() {
            presses.clear();
            mouseClick(orb, orb.width / 2, orb.height / 2);
            compare(presses.count, 1);
            compare(orb.active, false);
        }

        function test_tones_data() {
            return [
                { tag: "accent", color: "#123456" }, { tag: "info", color: "#234567" },
                { tag: "success", color: "#345678" }, { tag: "warning", color: "#456789" },
                { tag: "danger", color: "#56789a" }, { tag: "muted", color: "#6789ab" }
            ];
        }
        function test_tones(data) {
            const values = {};
            values[data.tag] = data.color;
            compare(UnitTheme.override({ voiceOrb: { tone: values } }), "ok");
            orb.tone = data.tag;
            compare(String(shader(orb).ink), data.color);
        }

        // expected-log: VoiceOrb: no tone named "loud" -- an unsupported tone must name its error and draw accent
        function test_unknown_tone() {
            orb.tone = "loud";
            compare(String(shader(orb).ink), String(Qt.color(Theme.voiceOrb.tone.accent)));
        }

        function test_levels_data() {
            return [
                { tag: "low", value: -1, expected: 0 }, { tag: "zero", value: 0, expected: 0 },
                { tag: "middle", value: 0.4, expected: 0.4 }, { tag: "one", value: 1, expected: 1 },
                { tag: "high", value: 2, expected: 1 }, { tag: "nan", value: NaN, expected: 0 },
                { tag: "infinite", value: Infinity, expected: 0 }
            ];
        }
        function test_levels(data) {
            orb.level = data.value;
            orb.secondaryLevel = data.value;
            fuzzyCompare(shader(orb).amplitude, data.expected, 0.000001);
            fuzzyCompare(shader(orb).secondaryAmplitude, data.expected, 0.000001);
        }

        function test_active_ticks_and_smooths() {
            orb.active = true;
            tryVerify(() => ticks.count > 0);
            const phase = shader(orb).phase;
            // A long token makes intermediate levels observable without a timing budget.
            compare(UnitTheme.override({ voiceOrb: { attack: 2000, release: 2000 } }), "ok");
            orb.level = 1;
            orb.secondaryLevel = 0.8;
            tryVerify(() => shader(orb).amplitude > 0 && shader(orb).secondaryAmplitude > 0);
            verify(shader(orb).amplitude < 1);
            verify(shader(orb).secondaryAmplitude < 0.8);
            verify(shader(orb).phase !== phase);
            const held = shader(orb).amplitude;
            orb.level = 0;
            tryVerify(() => shader(orb).amplitude < held);
            verify(shader(orb).amplitude > 0);
        }

        function test_smoothing_reads_the_timing_tokens() {
            const state = Array.from(orb.resources).find(child => typeof child.smooth === "function");
            fuzzyCompare(state.smooth(0, 1, 0.07), 1 - Math.exp(-1), 0.000001);
            fuzzyCompare(state.smooth(1, 0, 0.25), Math.exp(-1), 0.000001);
            compare(UnitTheme.override({ voiceOrb: { attack: 140, release: 500 } }), "ok");
            fuzzyCompare(state.smooth(0, 1, 0.07), 1 - Math.exp(-0.5), 0.000001);
            fuzzyCompare(state.smooth(1, 0, 0.25), Math.exp(-0.5), 0.000001);
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            compare(state.smooth(0, 1, 0.07), 1);
        }

        function test_stops_data() {
            return ["inactive", "hidden", "ancestor", "reduced", "zero-period"].map(tag => ({ tag: tag }));
        }
        function test_stops(data) {
            orb.active = true;
            tryVerify(() => ticks.count > 0);
            switch (data.tag) {
            case "inactive": orb.active = false; break;
            case "hidden": orb.visible = false; break;
            case "ancestor": holder.visible = false; break;
            case "reduced": compare(UnitTheme.override({ motion: { scale: 0 } }), "ok"); break;
            case "zero-period": compare(UnitTheme.override({ voiceOrb: { period: 0 } }), "ok"); break;
            default: fail("unknown stop case"); return;
            }
            still(orb, ticks);
            orb.level = 0.7;
            orb.secondaryLevel = 0.2;
            orb.tone = "danger";
            label.text = "Updated";
            fuzzyCompare(shader(orb).amplitude, 0.7, 0.000001);
            fuzzyCompare(shader(orb).secondaryAmplitude, 0.2, 0.000001);
            compare(String(shader(orb).ink), String(Qt.color(Theme.voiceOrb.tone.danger)));
            compare(label.text, "Updated");
        }

        function test_hidden_window_stops() {
            tryVerify(() => otherTicks.count > 0);
            otherWindow.visible = false;
            still(otherOrb, otherTicks);
            otherWindow.visible = true;
            const before = otherTicks.count;
            tryVerify(() => otherTicks.count > before);
        }

        function test_minimized_window_stops() {
            tryVerify(() => otherTicks.count > 0);
            otherWindow.visibility = Window.Minimized;
            still(otherOrb, otherTicks);
            otherWindow.visibility = Window.Windowed;
        }

        function cleanupTestCase() { otherWindow.visible = false; }
    }
}
