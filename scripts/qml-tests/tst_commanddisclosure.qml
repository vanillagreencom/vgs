import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// CommandDisclosure: it starts with its command hidden and adds no height
// for it; a click on "Show command" shows the command in a CodeLine and
// turns the button to "Hide command", and a second click hides it; the
// line copies the command; with no command nothing draws. A password
// TextField masks what is typed and keeps it off the clipboard.
Item {
    id: root
    width: 400
    height: 400

    CommandDisclosure { id: disclosure; width: 360; command: "loginctl enable-linger" }
    CommandDisclosure { id: empty; y: 200; width: 360; command: "" }
    // Never toggled, so it reads the state a disclosure starts in.
    CommandDisclosure { id: untouched; y: 230; width: 360; command: "vgsh plugin enable vgs.settings" }
    TextField { id: secret; y: 260; width: 200; password: true }
    // Reads the clipboard back.
    TextEdit { id: paste; y: 320; width: 360; height: 20 }

    TestCase {
        name: "commanddisclosure"
        when: windowShown

        function init() {
            UnitTheme.reset();
            disclosure.expanded = false;
            secret.clear();
        }

        function clipboardText() {
            paste.text = "";
            paste.paste();
            return paste.text;
        }

        function test_starts_hidden_and_takes_no_height_for_the_line() {
            compare(untouched.expanded, false);
            compare(untouched.line.visible, false);
            compare(untouched.toggle.text, "Show command");
            compare(disclosure.visible, true);
            compare(disclosure.line.visible, false);
            compare(disclosure.toggle.text, "Show command");
            compare(disclosure.toggle.variant, "ghost");
            compare(disclosure.height, disclosure.toggle.height);
        }

        function test_a_click_shows_the_command_and_a_second_hides_it() {
            mouseClick(disclosure.toggle);
            compare(disclosure.expanded, true);
            compare(disclosure.line.visible, true);
            compare(disclosure.line.text, "loginctl enable-linger");
            compare(disclosure.toggle.text, "Hide command");
            // A Column lays its children out at the next polish.
            tryCompare(disclosure, "height", disclosure.toggle.height + Theme.field.gap + disclosure.line.height);
            mouseClick(disclosure.toggle);
            compare(disclosure.expanded, false);
            compare(disclosure.line.visible, false);
            tryCompare(disclosure, "height", disclosure.toggle.height);
        }

        function test_the_line_copies_the_command() {
            disclosure.expanded = true;
            disclosure.line.copy();
            compare(clipboardText(), "loginctl enable-linger");
        }

        function test_no_command_draws_nothing() {
            compare(empty.visible, false);
        }

        function test_a_password_field_masks_and_keeps_its_text_off_the_clipboard() {
            disclosure.line.copy();
            compare(clipboardText(), "loginctl enable-linger", "a known text is on the clipboard first");
            secret.forceActiveFocus();
            keyClick("x");
            keyClick("o");
            compare(secret.text, "xo");
            compare(secret.echoMode, TextInput.Password);
            verify(secret.displayText !== "xo", "the field shows a mask");
            secret.selectAll();
            secret.copy();
            compare(clipboardText(), "loginctl enable-linger", "the masked text never reaches the clipboard");
        }
    }
}
