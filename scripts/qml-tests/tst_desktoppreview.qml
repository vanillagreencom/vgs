import QtQuick
import QtTest
import qs.Ui
import qs.Commons
import qs.Unit
import "../../shell/plugins/vgs.themes"

Item {
    id: root
    width: 640
    height: 360

    readonly property var samplePalette: ({
        background: "#101010ff",
        foreground: "#eeeeeeff",
        accent: "#3366ffff",
        success: "#00aa00ff",
        warning: "#ccaa00ff",
        danger: "#aa0000ff",
        info: "#0066aaff"
    })
    function terminalSlots() {
        const out = {};
        for (let i = 0; i < 16; i++) out["color" + i] = i === 1 ? "#aa0000ff" : "#202020ff";
        return out;
    }

    DesktopPreview {
        id: preview
        width: 400
        height: 250
        title: "Probe"
        commandLine: "vgsh theme apply probe"
        tokens: ({
            palette: root.samplePalette,
            color: {
                surfaceRaised: "#222222ff",
                border: "#444444ff",
                borderSubtle: "#333333ff",
                textMuted: "#888888ff"
            },
            hyprland: {
                border: { size: 4 },
                window: { radius: 8 },
                shadow: { color: "#00000080" }
            }
        })
        terminal: root.terminalSlots()
        decodeSize: Qt.size(800, 500)
    }

    TestCase {
        name: "desktopPreview"
        when: windowShown

        function cleanupTestCase() { UnitTheme.reset(); }

        function descendants(item) {
            const out = [item];
            for (let i = 0; i < out.length; i++)
                for (const child of out[i].children || []) out.push(child);
            return out;
        }
        function rects() { return descendants(preview).filter(child => String(child).startsWith("QQuickRectangle(")); }
        function images() { return preview.children.filter(child => child instanceof Image); }
        function labels() {
            const out = [];
            function walk(item) {
                if (item instanceof Text && item.text !== "") out.push(item.text);
                for (const child of item.children) walk(child);
            }
            walk(preview);
            return out;
        }

        function test_preview_uses_the_package_palette() {
            compare(String(preview.backgroundColor), "#101010");
            compare(String(preview.foregroundColor), "#eeeeee");
            compare(String(preview.accentColor), "#3366ff");
            compare(String(preview.activeBorderColor), "#3366ff");
            compare(String(preview.inactiveBorderColor), "#444444");
            preview.tokens = Object.assign({}, preview.tokens, { palette: Object.assign({}, root.samplePalette, { accent: "#ff0000ff" }) });
            compare(String(preview.accentColor), "#ff0000");
            compare(String(preview.activeBorderColor), "#ff0000");
        }

        function test_preview_uses_terminal_and_hyprland_tokens() {
            compare(preview.borderSize, 4);
            compare(preview.windowRadius, 8);
            compare(String(preview.terminalColor(1)), "#ffaa0000");
            preview.tokens = Object.assign({}, preview.tokens, { hyprland: { border: { size: 7 }, window: { radius: 12 }, shadow: { color: "#00000080" } } });
            compare(preview.borderSize, 7);
            compare(preview.windowRadius, 12);
        }

        function test_wallpaper_decodes_at_the_handed_size() {
            compare(images()[0].sourceSize, Qt.size(800, 500));
        }

        // The three windows, each a Rectangle holding its content Column,
        // in x then y order: the terminal, the editor, the notification.
        function windows() {
            return descendants(preview).filter(child => String(child).startsWith("QQuickRectangle(") && child.children.some(c => String(c).startsWith("QQuickColumn(")))
                .sort((a, b) => a.x - b.x || a.y - b.y);
        }
        function content(box) { return box.children.find(c => String(c).startsWith("QQuickColumn(")); }
        function withRadius(radius) {
            preview.tokens = Object.assign({}, preview.tokens, { hyprland: { border: { size: 4 }, window: { radius: radius }, shadow: { color: "#00000080" } } });
        }

        // A 32 px window corner with the content's top 12 in: dy = 32 - 12
        // = 20, reach = 32 - 4 = 28, 32 - sqrt(28^2 - 20^2) = 12.40, so
        // each window's content stands 13 in; an 8 px corner keeps the
        // 12 px padding.
        function test_window_content_clears_the_theme_window_corner() {
            preview.width = 400;
            preview.height = 250;
            withRadius(32);
            const boxes = windows();
            compare(boxes.length, 3);
            for (const box of boxes) compare([content(box).x, content(box).y], [13, 13]);
            withRadius(8);
            for (const box of windows()) compare([content(box).x, content(box).y], [12, 12]);
        }

        // 400 by 250: scale = max(400 / 1600, 250 / 900) = 250 / 900, so the
        // card's 28 px lean is 28 * 900 / 250 = 100.8 reference px and the
        // safe inset 24 + 100.8 = 124.8. The terminal and the notification
        // end at 900 - 124.8 = 775.2; the right side's overhang would put
        // them at 695.2.
        function test_the_windows_end_at_the_safe_inset() {
            preview.width = 400;
            preview.height = 250;
            withRadius(8);
            const [terminal, editor, notification] = windows();
            fuzzyCompare(terminal.y + terminal.height, 775.2, 1e-6);
            fuzzyCompare(notification.y + notification.height, 775.2, 1e-6);
            verify(notification.y > editor.y, "the notification sits under the editor");
        }

        function test_mock_desktop_covers_different_card_aspects() {
            const aspects = [[400, 250], [520, 250]];
            for (const size of aspects) {
                preview.width = size[0];
                preview.height = size[1];
                verify(preview.mockBounds.x <= 0, "left covers " + size);
                verify(preview.mockBounds.y <= 0, "top covers " + size);
                verify(preview.mockBounds.x + preview.mockBounds.width >= preview.width, "right covers " + size);
                verify(preview.mockBounds.y + preview.mockBounds.height >= preview.height, "bottom covers " + size);
            }
        }
    }
}
