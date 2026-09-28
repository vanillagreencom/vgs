import QtQuick
import QtTest
import qs.Commons
import qs.Unit

// A plugin-owned appearance, Theme.appearance: a plugin's own table
// resolved against the theme's scheme.mode, palette.accent and motion.scale
// and nothing else of it. Every other shell token moves and the plugin's
// values stay, read back from bindings and from pixels; the mode applies the
// light overrides, the accent reaches the plugin, and the motion scale
// reaches its durations. A table the judge refuses answers null.
Item {
    id: root
    width: 200
    height: 100

    // A table in the plugin shape: the accent, the motion scale, and the
    // plugin's own values.
    readonly property var table: ({
        palette: { accent: { type: "color", value: "#000000" } },
        motion: { scale: { type: "number", value: 1, min: 0, max: 4 }, open: { type: "duration", value: 200 } },
        card: {
            fill: { type: "color", value: "#151515" },
            edge: { type: "color", value: "alpha({palette.accent}, 0.5)" },
            radius: { type: "length", value: 18 },
            family: { type: "family", value: "JetBrains Mono" }
        }
    })
    readonly property var light: ({ card: { fill: "#efefef" } })
    readonly property var look: Theme.appearance(table, light)

    Rectangle { id: card; width: 20; height: 20; color: root.look.card.fill }
    Rectangle { id: edge; x: 30; width: 20; height: 20; color: root.look.card.edge }

    TestCase {
        name: "appearance"
        when: windowShown

        function init() { UnitTheme.reset(); }

        function test_dark_defaults() {
            compare(root.look.card.fill, "#ff151515");
            compare(root.look.palette.accent, "#ffff5a36");
            compare(root.look.card.edge, "#80ff5a36");
            compare(root.look.card.radius, 18);
            compare(root.look.card.family, "JetBrains Mono");
            compare(root.look.motion.open, 200);
            verify(Object.isFrozen(root.look.card));
        }

        function test_unrelated_tokens_leave_the_look() {
            const before = JSON.stringify(root.look);
            compare(UnitTheme.override({
                palette: { foreground: "#ff00ff", background: "#00ff00", success: "#123456", danger: "#654321" },
                font: { size: 22, family: { mono: "Serif", sans: "Serif" } },
                space: { unit: 7 },
                radius: { md: 9, sm: 5 },
                color: { surface: "#ff0000", text: "#00ffff" },
                text: { body: { size: 30, weight: 800 } },
                surface: { padding: 40 }
            }), "ok");
            compare(JSON.stringify(root.look), before);
            wait(50);
            const img = grabImage(card);
            verify(img.red(10, 10) < 40 && img.green(10, 10) < 40 && img.blue(10, 10) < 40, "the card draws its own dark fill");
        }

        function test_mode_applies_the_light_overrides() {
            compare(UnitTheme.override({ scheme: { mode: "light" } }), "ok");
            compare(root.look.card.fill, "#ffefefef");
            compare(root.look.card.radius, 18);
            wait(50);
            const img = grabImage(card);
            verify(img.red(10, 10) > 220 && img.green(10, 10) > 220, "the card draws its light fill");
        }

        function test_accent_reaches_the_look() {
            compare(UnitTheme.override({ palette: { accent: "#7aa2f7" } }), "ok");
            compare(root.look.palette.accent, "#ff7aa2f7");
            compare(root.look.card.edge, "#807aa2f7");
            compare(root.look.card.fill, "#ff151515");
        }

        function test_motion_scale_reaches_the_durations() {
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            compare(root.look.motion.open, 0);
            compare(UnitTheme.override({ motion: { scale: 2 } }), "ok");
            compare(root.look.motion.open, 400);
        }

        function test_a_refused_table_answers_null() {
            compare(Theme.appearance(root.table, { palette: { accent: "#ffffff" } }), null);
        }
    }
}
