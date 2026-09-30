import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// CodeLine: a click on its Copy button puts its text on the clipboard,
// emits `copied` once and shows a check mark for `codeLine.confirm`
// milliseconds; a long text wraps inside the line, clear of the button,
// and the line grows to hold it; the fill and the text read their tokens.
Item {
    id: root
    width: 400
    height: 300

    CodeLine {
        id: line
        width: 360
        text: "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"
        copyLabel: "Copy the command"
    }
    CodeLine { id: short; y: 120; width: 360; text: "vgsh plugin update acme.weather" }
    // Reads the clipboard back.
    TextEdit { id: paste; y: 200; width: 360; height: 20 }
    SignalSpy { id: copies; target: line; signalName: "copied" }

    TestCase {
        name: "codeline"
        when: windowShown

        function init() { UnitTheme.reset(); copies.clear(); paste.text = ""; }

        function label(item) { return item.children[0]; }
        function button(item) { return item.children[1]; }

        function clipboardText() {
            paste.text = "";
            paste.paste();
            return paste.text;
        }

        function test_copy_puts_the_text_on_the_clipboard() {
            short.copy();
            compare(clipboardText(), "vgsh plugin update acme.weather", "a known text is on the clipboard first");
            mouseClick(button(line));
            compare(copies.count, 1);
            compare(clipboardText(), line.text);
        }

        function test_copy_shows_a_check_mark_for_its_token() {
            // A copy by an earlier case confirms for the default duration.
            tryCompare(line, "confirming", false, 3000);
            compare(UnitTheme.override({ codeLine: { confirm: 80 } }), "ok");
            compare(button(line).iconName, "copy");
            compare(button(line).label, "Copy the command");
            compare(button(line).size, "sm");
            line.copy();
            compare(line.confirming, true);
            compare(button(line).iconName, "check");
            tryCompare(button(line), "iconName", "copy", 1000);
        }

        function test_a_long_text_wraps_clear_of_the_button() {
            verify(label(line).lineCount > 1, "the command wraps: lines=" + label(line).lineCount);
            compare(label(short).lineCount, 1);
            verify(label(line).x + label(line).width <= button(line).x - Theme.codeLine.gap, "the text ends before the button");
            compare(button(line).x + button(line).width, line.width - Theme.codeLine.padding);
            compare(button(line).y, Theme.codeLine.padding);
            compare(line.height, 2 * Theme.codeLine.padding + Math.max(label(line).lineCount * label(line).lineBox, button(line).implicitHeight));
            verify(line.height > short.height, "the wrapped line is taller");
        }

        // The text breaks between words: the first line of the command,
        // whose next word does not fit, ends more than one glyph short of
        // the line's width, where a break inside the word would fill it.
        function test_a_wrap_lands_between_words() {
            const text = label(line);
            verify(text.lineCount > 1, "the command wraps");
            wait(50);
            const img = grabImage(text);
            let right = -1;
            for (let x = 0; x < img.width; x++)
                for (let y = 0; y < text.lineBox; y++)
                    if (img.red(x, y) > 96) right = Math.max(right, x);
            const glyph = text.font.pixelSize * 0.6;
            verify(right > 0, "the first line drew");
            verify(right < text.width - glyph, "the first line's ink ends at " + right + " of " + text.width + ", a break between words");
        }

        function test_geometry_uses_equal_padding_and_optical_placement() {
            compare(label(short).x, Theme.codeLine.padding);
            compare(button(short).x + button(short).width, short.width - Theme.codeLine.padding);
            compare(button(short).y, Theme.codeLine.padding);
            fuzzyCompare(label(short).y + label(short).capCentre, short.height / 2, 1);
            fuzzyCompare(label(line).y - label(line).halfLeading, Theme.codeLine.padding, 0.5);
            fuzzyCompare(line.height - (label(line).y - label(line).halfLeading + label(line).lineCount * label(line).lineBox), Theme.codeLine.padding, 1);
        }

        function test_the_line_reads_its_tokens() {
            compare(label(line).role, "code");
            compare(String(line.color), String(Qt.color(Theme.codeLine.background)));
            compare(UnitTheme.override({ codeLine: { background: "#00ff00ff", foreground: "#0000ffff" } }), "ok");
            compare(String(line.color), "#00ff00");
            compare(String(label(line).color), "#0000ff");
        }
    }
}
