import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit
import "../../shell/plugins/vgs.jarvis"
import "../../shell/plugins/vgs.jarvis/Session.js" as Session

// The Jarvis bar widget: the icon and tone it draws for the status values a
// stand-in `shell` hands it, and that a click, Space, Return and keypad
// Enter each make exactly one `mute` call through `shell.ipc`. The bar
// layer takes no keyboard focus in the live shell, so this test is where
// the keys are proven. WidgetView.js's own table is
// scripts/test-jarvis-widget.js; this test reads what the widget draws.
Item {
    id: root
    width: 200
    height: 60

    property var calls: []
    property string reply: "ok"

    // A shell with VALUES as its status and an ipc that records each call.
    function shellWith(values) {
        return {
            status: { values: values },
            ipc: { call: (name, arg) => { root.calls = root.calls.concat([[name, arg]]); return root.reply; } }
        };
    }
    // Status values over Session's initial record with REGIONS set.
    function ready(regions) {
        const s = Object.assign(JSON.parse(JSON.stringify(Session.initial())), { gate: { kind: "up" } }, regions);
        return { daemon: { tone: "info", text: "Ready; no capture" }, audio: { tone: "ok", text: "Device list ready" },
            detail: { phase: Session.phaseOf(s), seq: 1, state: s } };
    }

    Widget { id: widget }

    TestCase {
        name: "jarvisWidget"
        when: windowShown

        function init() {
            UnitTheme.reset();
            root.calls = [];
            root.reply = "ok";
            widget.shell = root.shellWith(root.ready({}));
        }

        function find(node, test) {
            if (test(node)) return node;
            for (const child of node.children) {
                const found = find(child, test);
                if (found !== null) return found;
            }
            return null;
        }
        function button() { return find(widget, n => n.iconName !== undefined && n.label !== undefined); }
        function tooltip() { return find(widget, n => n.anchorItem !== undefined && n.text !== undefined); }
        function icon() { return find(button().contentItem, n => n.name !== undefined && n.paths !== undefined); }

        function test_states_draw_their_icon_tone_and_tooltip() {
            const rows = [
                [{ daemon: { tone: "info", text: "Starting" }, detail: null }, "power-off", Theme.badge.tone.neutral.foreground, "Jarvis: Starting\nClick to mute"],
                [root.ready({}), "mic", Theme.bar.foreground, "Jarvis is ready\nClick to mute"],
                [root.ready({ capture: { kind: "open", gen: 1, op: 2, mode: "hold" } }), "audio-lines", Theme.badge.tone.accent.foreground, "Jarvis is using the microphone\nClick to mute"],
                [root.ready({ turn: { kind: "thinking", gen: 1, op: 3, deadline: 70 } }), "loader", Theme.badge.tone.info.foreground, "Jarvis is thinking\nClick to mute"],
                [root.ready({ mute: { kind: "on" } }), "mic-off", Theme.badge.tone.neutral.foreground, "Jarvis is muted\nClick to unmute"],
                [{ daemon: { tone: "danger", text: "Problem: jarvis: node=21.0.0 need=22" }, detail: null }, "circle-alert", Theme.badge.tone.danger.foreground, "Problem: jarvis: node=21.0.0 need=22\nClick to mute"]
            ];
            for (const [values, name, colour, text] of rows) {
                widget.shell = root.shellWith(values);
                compare(icon().name, name, name);
                compare(String(icon().color), String(Qt.color(colour)), name + " colour");
                compare(button().label, "Jarvis");
                compare(tooltip().text, text);
            }
        }

        function test_a_click_calls_mute_once() {
            mouseClick(button());
            compare(JSON.stringify(root.calls), '[["mute",""]]');
        }

        function test_space_return_and_enter_each_call_mute_once() {
            for (const key of [Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter]) {
                root.calls = [];
                button().forceActiveFocus();
                verify(button().activeFocus, "the button holds focus");
                keyClick(key);
                compare(JSON.stringify(root.calls), '[["mute",""]]', "key " + key);
            }
        }

        // expected-log: jarvis widget: mute unknown: mute -- the widget reports a reply other than ok
        function test_a_refused_reply_is_reported() {
            root.reply = "unknown: mute";
            compare(widget.toggleMute(), "unknown: mute");
        }

        function test_an_unknown_tone_throws() {
            let message = "";
            try { widget.toneColor("loud"); } catch (e) { message = e.message; }
            compare(message, 'jarvis widget: tone "loud" is not one of calm, accent, info, danger, neutral');
        }
    }
}
