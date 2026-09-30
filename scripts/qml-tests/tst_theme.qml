import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Theme reaches a component: a published value is the theme's, a theme
// change re-evaluates a binding without rebuilding the item, the revision
// rises after the groups hold the new theme, and a refused document changes
// nothing. The pixel rows read colours back from a rendered item.
Item {
    id: root
    width: 200
    height: 100

    Rectangle { id: filled; width: 20; height: 20; color: Theme.color.accent }
    Button { id: button; text: "Go"; y: 40 }
    property int revisionsSeen: 0
    property string accentAtRevision: ""
    Connections {
        target: Theme
        function onRevisionChanged() { root.revisionsSeen += 1; root.accentAtRevision = Theme.color.accent; }
    }

    TestCase {
        name: "theme"
        when: windowShown

        function init() { UnitTheme.reset(); }

        function test_default_values() {
            compare(Theme.name, "vgs");
            compare(Theme.color.accent, "#ffff5a36");
            compare(Theme.text.body.family, "Inter Variable");
            compare(Theme.text.label.family, "JetBrains Mono");
            compare(Theme.bar.height, 28);
            compare(Theme.motion.duration.fast, 100);
        }

        function test_groups_are_frozen() {
            verify(Object.isFrozen(Theme.color));
            verify(Object.isFrozen(Theme.text.body));
            Theme.color.accent = "#ff000000";
            compare(Theme.color.accent, "#ffff5a36");
        }

        function test_change_reaches_a_binding_without_a_rebuild() {
            const before = filled;
            compare(String(filled.color), "#ff5a36");
            compare(UnitTheme.override({ palette: { accent: "#00ff00" } }), "ok");
            compare(String(filled.color), "#00ff00");
            verify(filled === before);
            // The button's fill animates to the new theme.
            tryCompare(button.background, "color", Qt.color("#00ff00"));
        }

        function test_revision_rises_after_the_groups() {
            const seen = root.revisionsSeen;
            const revision = Theme.revision;
            compare(UnitTheme.override({ palette: { accent: "#0000ff" } }), "ok");
            compare(Theme.revision, revision + 1);
            compare(root.revisionsSeen, seen + 1);
            compare(root.accentAtRevision, "#ff0000ff");
        }

        function test_refused_document_changes_nothing() {
            compare(UnitTheme.override({ palette: { accent: "#123456" } }), "ok");
            const revision = Theme.revision;
            compare(UnitTheme.override({ palette: { acent: "#000000" } }), "theme: refused: token=palette.acent reason=unknown-token");
            compare(Theme.color.accent, "#ff123456");
            compare(Theme.revision, revision);
        }

        function test_pixels_follow_the_theme() {
            compare(UnitTheme.override({ palette: { accent: "#ff0000" } }), "ok");
            wait(100);
            const img = grabImage(filled);
            verify(img.red(10, 10) > 200 && img.green(10, 10) < 50, "the rectangle draws the accent");
        }
    }
}
