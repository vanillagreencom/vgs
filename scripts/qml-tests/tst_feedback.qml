import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// Spinner, ProgressBar, Badge and Kbd: the spinner turns only while the
// theme's duration is above zero, the bar's fill follows its position and
// slides while indeterminate, a badge draws its tone and logs an unknown
// one, and a key cap sizes to its text and draws it in the kbd role.
Item {
    id: root
    width: 300
    height: 200

    Spinner { id: spinner }
    ProgressBar { id: progress; value: 0.25; width: 200; y: 30 }
    ProgressBar { id: busy; indeterminate: true; width: 200; y: 50 }
    ProgressBar { id: mirroredBar; value: 0.25; width: 200; y: 60; LayoutMirroring.enabled: true }
    Badge { id: badge; text: "Verified"; tone: "success"; y: 70 }
    Badge { id: badgeIcon; text: "Verified"; tone: "success"; iconName: "check"; y: 100 }
    Badge { id: badgeMd; text: "Verified"; tone: "success"; size: "md"; y: 130 }
    Kbd { id: kbd; text: "Ctrl"; y: 160 }

    TestCase {
        name: "feedback"
        when: windowShown

        function init() { UnitTheme.reset(); }

        function fill(bar) { return bar.contentItem.children[0]; }
        function badgeLabel(item) { return item.children.find(child => child.role === "label"); }
        function badgeIconItem(item) { return item.children.find(child => child.name === item.iconName); }
        function kbdLabel(item) { return item.children[0]; }

        function test_spinner_turns_and_reduced_motion_stops_it() {
            compare(spinner.width, Theme.spinner.size);
            const shape = spinner.children[0];
            const angle = shape.rotation;
            wait(100);
            verify(shape.rotation !== angle, "the arc turned");
            compare(UnitTheme.override({ motion: { scale: 0 } }), "ok");
            compare(Theme.spinner.duration, 0);
            const still = shape.rotation;
            wait(100);
            compare(shape.rotation, still);
        }

        function test_progress_fill_follows_the_value() {
            fuzzyCompare(fill(progress).width, progress.contentItem.width / 4, 1);
            compare(progress.height, Theme.progress.height);
            compare(String(fill(progress).color), String(Qt.color(Theme.progress.fill)));
            const slide = fill(busy).x;
            fuzzyCompare(fill(busy).width, busy.contentItem.width * Theme.progress.indeterminateShare, 1);
            wait(150);
            verify(fill(busy).x !== slide, "the indeterminate fill moved");
            // Leaving the indeterminate state returns the fill to the origin.
            busy.indeterminate = false;
            busy.value = 1;
            tryCompare(fill(busy), "x", 0);
            fuzzyCompare(fill(busy).width, busy.contentItem.width, 1);
            busy.indeterminate = true;
        }

        function test_mirrored_progress_fills_from_the_right() {
            fuzzyCompare(fill(mirroredBar).width, mirroredBar.contentItem.width / 4, 1);
            fuzzyCompare(fill(mirroredBar).x + fill(mirroredBar).width, mirroredBar.contentItem.width, 1);
            mirroredBar.value = 0;
            fuzzyCompare(fill(mirroredBar).width, 0, 1);
            mirroredBar.value = 0.25;
        }

        // expected-log: Badge: no tone named "loud" -- the test names an unknown tone on purpose
        function test_badge_draws_its_tone() {
            compare(String(badge.color), String(Qt.color(Theme.badge.tone.success.background)));
            compare(badge.height, Theme.badge.size.sm.height);
            compare(badgeMd.height, Theme.badge.size.md.height);
            const odd = Qt.createQmlObject("import qs.Ui\nBadge { tone: \"loud\"; text: \"x\" }", root);
            compare(String(odd.color), String(Qt.color(Theme.badge.tone.neutral.background)));
            odd.destroy();
        }

        function test_badge_centres_text_and_uses_optical_width() {
            const label = badgeLabel(badge);
            fuzzyCompare(label.y + label.capCentre, badge.height / 2, 1);
            fuzzyCompare(label.x, Theme.badge.size.sm.paddingX, 0.5);
            fuzzyCompare(badge.width - (label.x + label.opticalWidth), Theme.badge.size.sm.paddingX, 0.5);
            const icon = badgeIconItem(badgeIcon);
            const iconLabel = badgeLabel(badgeIcon);
            fuzzyCompare(icon.y + icon.height / 2, badgeIcon.height / 2, 1);
            fuzzyCompare(iconLabel.y + iconLabel.capCentre, badgeIcon.height / 2, 1);
            fuzzyCompare(badgeIcon.width, 2 * Theme.badge.size.sm.paddingX + icon.width + Theme.badge.gap + iconLabel.opticalWidth, 0.5);
        }

        function test_kbd_sizes_to_its_text() {
            verify(kbd.width > 2 * Theme.kbd.paddingX, "the cap is wider than its padding");
            compare(kbd.border.width, Theme.kbd.border);
            const label = kbdLabel(kbd);
            compare(kbd.height, label.lineBox + 2 * Theme.kbd.paddingY);
            compare(kbd.height, 19);
            fuzzyCompare(label.x, Theme.kbd.paddingX, 0.1);
            fuzzyCompare(kbd.width - (label.x + label.opticalWidth), Theme.kbd.paddingX, 0.1);
            fuzzyCompare(label.y + label.capCentre, kbd.height / 2, 0.5);
            compare(UnitTheme.override({ kbd: { paddingX: 12, paddingY: 2, background: "#00ff00" } }), "ok");
            compare(String(kbd.color), "#00ff00");
            verify(kbd.width > 24, "wider padding widens the cap");
            compare(kbd.height, 19);
        }

        function test_kbd_draws_the_kbd_role() {
            const label = kbd.children[0];
            compare(label.font.pixelSize, Theme.text.kbd.size);
            compare(label.font.weight, Theme.text.kbd.weight);
            compare(label.lineHeight, label.lineBox);
        }
    }
}
