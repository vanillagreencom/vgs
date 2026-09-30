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
