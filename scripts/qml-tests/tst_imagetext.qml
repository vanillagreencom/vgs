import QtQuick
import QtTest
import qs.Ui

// ImageText: an image segment draws as an image at full strength whatever
// the text's colour, and a line holding one keeps the pitch of a line
// without; text with no image draws through Qt's own right elision; text
// with images cut short ends at a whole word or image with one ellipsis,
// draws no image past the cut and none on a line it does not sit on; an
// image that fails draws its alt text; and ImagePool shares one image per
// URL and size between holders and lets it go with the last. Pixels are
// read off grabs; the red of the fixture image is never a colour of the
// text.
Item {
    id: root
    width: 420
    height: 300

    readonly property string red: Qt.resolvedUrl("images/red.png")
    readonly property string missing: Qt.resolvedUrl("images/missing.png")
    readonly property font face: Qt.font({ family: "Liberation Sans", pixelSize: 20 })

    function words(count) {
        const out = [];
        for (let i = 0; i < count; i++) out.push("word" + i);
        return out.join(" ");
    }

    Component {
        id: textComponent
        ImageText {
            width: 400
            font: root.face
            color: "#80000000"
            maximumLineCount: 2
        }
    }

    TestCase {
        name: "imagetext"
        when: windowShown

        function make(segments, lines) {
            const item = createTemporaryObject(textComponent, root, { segments: segments, maximumLineCount: lines || 2 });
            verify(item !== null);
            return item;
        }

        // The Text the component draws: its one visible child.
        function drawn(item) {
            for (const child of item.children)
                if (child.visible && child.text !== undefined) return child;
            fail("no drawn text");
        }

        // The rows of the item that hold a red pixel of the fixture image.
        function redRows(item) {
            const img = grabImage(item);
            const rows = [];
            for (let y = 0; y < img.height; y++) {
                for (let x = 0; x < img.width; x++) {
                    if (img.red(x, y) > 200 && img.green(x, y) < 60 && img.blue(x, y) < 60 && img.alpha(x, y) > 200) {
                        rows.push(y);
                        break;
                    }
                }
            }
            return rows;
        }

        function redAlpha(item) {
            const img = grabImage(item);
            let best = 0;
            for (let y = 0; y < img.height; y++)
                for (let x = 0; x < img.width; x++)
                    if (img.red(x, y) > 200 && img.green(x, y) < 60 && img.blue(x, y) < 60) best = Math.max(best, img.alpha(x, y));
            return best;
        }

        function test_an_image_segment_draws_as_an_image_at_full_strength() {
            const item = make([{ markup: "a " }, { image: root.red, alt: ":red:" }, { markup: " b" }], 1);
            verify(drawn(item).text.indexOf("<img") !== -1, "the text names the image");
            tryVerify(() => redRows(item).length > 0, 3000, "the image is drawn");
            compare(redAlpha(item), 255, "the image draws at full strength under a half-alpha text colour");
            verify(redRows(item).length <= item.imageSize, "the image is one line's height");
        }

        function test_a_line_with_an_image_keeps_its_pitch() {
            const plain = make([{ markup: "a b" }], 1);
            const imaged = make([{ markup: "a " }, { image: root.red, alt: ":red:" }, { markup: " b" }], 1);
            compare(imaged.implicitHeight, plain.implicitHeight);
        }

        function test_text_without_images_uses_qt_elision() {
            const item = make([{ markup: words(80) }], 2);
            compare(drawn(item).elide, Text.ElideRight);
            compare(drawn(item).text, words(80));
            verify(item.truncated);
            compare(item.lineCount, 2);
        }

        function test_a_cut_body_ends_at_a_whole_token_with_no_image_misplaced() {
            const full = "one " + words(80);
            const item = make([{ markup: "one " }, { image: root.red, alt: ":red:" }, { markup: " " + words(80) }], 2);
            const text = drawn(item).text;
            verify(text.endsWith("\u2026"), "one ellipsis ends the text: " + text);
            compare(text.split("\u2026").length, 2);
            const kept = text.slice(0, -1).replace(/<img[^>]*>/, "").trim().split(/\s+/);
            compare(kept, full.split(" ").slice(0, kept.length), "the cut keeps whole words from the start: " + text);
            verify(item.truncated);
            compare(item.lineCount, 2);
            tryVerify(() => redRows(item).length > 0, 3000, "the image is drawn");
            const lineHeight = item.implicitHeight / 2;
            const rows = redRows(item);
            verify(rows[rows.length - 1] < lineHeight, "the image stays on the first line, last red row " + rows[rows.length - 1] + " line height " + lineHeight);
        }

        function test_an_image_past_the_cut_is_not_drawn() {
            const item = make([{ markup: words(80) + " " }, { image: root.red, alt: ":red:" }], 2);
            verify(drawn(item).text.indexOf("<img") === -1, "the image past the cut is not in the text");
            wait(200);
            compare(redRows(item).length, 0);
        }

        // expected-log: Cannot open: -- the missing fixture image fails to load on purpose
        function test_a_failed_image_draws_its_alt_text() {
            const item = make([{ markup: "x " }, { image: root.missing, alt: ":gone:" }], 1);
            tryVerify(() => drawn(item).text.indexOf(":gone:") !== -1, 3000, "the alt text replaces the image");
            verify(drawn(item).text.indexOf("<img") === -1);
        }

        function test_the_pool_shares_an_image_and_lets_it_go_with_its_last_holder() {
            const segments = [{ image: root.red, alt: ":red:" }];
            const first = make(segments, 1);
            const size = first.deviceSize;
            const held = () => ImagePool.entries[size + "@" + root.red];
            compare(held().holders, 1);
            const second = make(segments, 1);
            compare(held().holders, 2, "two holders share one entry");
            second.segments = [{ markup: "none" }];
            compare(held().holders, 1, "a holder that stops naming the image releases it");
            first.destroy();
            tryVerify(() => held() === undefined, 1000, "the last release lets the image go");
        }
    }
}
