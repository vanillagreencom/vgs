#!/usr/bin/env node
// ImageText's decisions, shell/Ui/foundation/ImageTextLogic.js, under
// node: which image URLs draw, how markup is cut into tokens, what an image
// and a failed image write, and where the elision cuts. Expected values are
// written out by hand. The controls at the end edit a copy of the logic,
// one rule at a time, and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const source = path.join(__dirname, "..", "shell", "Ui", "foundation", "ImageTextLogic.js");
const logic = load(process.env.IMAGE_TEXT_LOGIC || source);
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message);
const RED = "file:///cache/emoji/0123456789abcdef.png?v=0123456789abcdef";

// URLs: [label, url, drawn].
for (const [label, url, drawn] of [
    ["a local file", RED, true],
    ["a path with a space", "file:///home/a b/x.png", true],
    ["a remote image", "https://emoji.slack-edge.com/T1/x/1.png", false],
    ["a quote that would end the attribute", "file:///x\".png", false],
    ["a tag opener", "file:///x<b>.png", false],
    ["an entity", "file:///x&amp;.png", false],
    ["no URL", undefined, false]
]) assert.equal(logic.drawableUrl(url), drawn, "drawable: " + label);

// Tokens: a cut falls between them, never inside a tag or an entity.
same(logic.markupTokens("a <b>bold</b>  x&amp;y<br/>z <i"), [
    { kind: "word", markup: "a" }, { kind: "space", markup: " " }, { kind: "tag", markup: "<b>" }, { kind: "word", markup: "bold" },
    { kind: "tag", markup: "</b>" }, { kind: "space", markup: "  " }, { kind: "word", markup: "x&amp;y" }, { kind: "break", markup: "<br/>" },
    { kind: "word", markup: "z" }, { kind: "space", markup: " " }, { kind: "tag", markup: "<i" }
], "markup tokens");

// An image writes one sized, middle-aligned tag; a failed, remote or
// unsafe one writes its alt text escaped.
same(logic.tokens([{ markup: "hi " }, { image: RED, alt: ":red:" }], 12, []), [
    { kind: "word", markup: "hi" }, { kind: "space", markup: " " },
    { kind: "image", markup: "<img src=\"" + RED + "\" width=\"12\" height=\"12\" align=\"middle\">" }
], "an image token");
same(logic.tokens([{ image: RED, alt: ":red:" }], 12, [RED]), [{ kind: "word", markup: ":red:" }], "a failed image writes its alt text");
same(logic.tokens([{ image: "http://h/x.png", alt: "<img src=x>" }], 12, []), [
    { kind: "word", markup: "&lt;img" }, { kind: "space", markup: " " }, { kind: "word", markup: "src=x&gt;" }
], "alt text is escaped");
same(logic.imageUrls([{ image: RED }, { markup: "x" }, { image: RED }, { image: "http://h/x.png" }]), [RED], "unique drawable URLs");

// Elision against a stand-in measure: markup fits when its text, tags
// removed and an image counted as one character, is at most `room` long.
const measure = room => markup => markup.replace(/<img[^>]*>/g, "#").replace(/<[^>]*>/g, "").replace(/&[a-z]+;/g, "&").length <= room;
const list = logic.tokens([{ markup: "one <b>two</b> " }, { image: RED, alt: ":red:" }, { markup: " three<br/>four" }], 12, []);
const whole = "one <b>two</b> <img src=\"" + RED + "\" width=\"12\" height=\"12\" align=\"middle\"> three<br/>four";
same(logic.elide(list, measure(100)), { markup: whole, cut: false }, "text that fits is whole");
same(logic.elide(list, measure(10)), { markup: "one <b>two</b> <img src=\"" + RED + "\" width=\"12\" height=\"12\" align=\"middle\">\u2026", cut: true }, "the cut keeps a whole image");
same(logic.elide(list, measure(8)), { markup: "one <b>two\u2026", cut: true }, "the cut ends on a whole word, without the space after it");
same(logic.elide(list, measure(16)), { markup: "one <b>two</b> <img src=\"" + RED + "\" width=\"12\" height=\"12\" align=\"middle\"> three\u2026", cut: true }, "a line break before the cut goes");
same(logic.elide(list, measure(0)), { markup: "\u2026", cut: true }, "nothing fits: the ellipsis alone");
let asked = 0;
logic.elide(logic.tokens([{ markup: Array.from({ length: 1000 }, (_, i) => "w" + i).join(" ") }], 12, []), markup => { asked++; return markup.length < 50; });
assert.ok(asked <= 12, "the cut bisects: " + asked + " measures for 1000 words");

function controls() {
    const text = fs.readFileSync(source, "utf8");
    const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "test-image-text-logic-"));
    const table = [
        ["only local files draw", "/^file:\\/\\/\\/[^\"<>&]+$/.test(url)", "true", /drawable: a remote image/],
        ["alt text is escaped", "out = out.concat(markupTokens(escape(segment.alt)));", "out = out.concat(markupTokens(segment.alt));", /alt text is escaped/],
        ["a failed image draws no image", "failed.indexOf(segment.image) === -1", "true", /a failed image writes its alt text/],
        ["the cut ends on a word or an image", "if (list[i].kind === \"word\" || list[i].kind === \"image\") out.push(i + 1);", "out.push(i + 1);", /without the space after it|line break before the cut/],
        ["the cut bisects", "var mid = (low + high) >> 1;", "var mid = low;", /the cut bisects/]
    ];
    let passed = 0;
    try {
        for (const [label, needle, replacement, failure] of table) {
            assert.equal(text.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
            const copy = path.join(dir, passed + ".js");
            fs.writeFileSync(copy, text.replace(needle, () => replacement));
            const result = childProcess.spawnSync(process.execPath, [__filename], {
                env: { PATH: process.env.PATH, IMAGE_TEXT_LOGIC: copy, IMAGE_TEXT_LOGIC_SKIP_CONTROLS: "1" },
                encoding: "utf8"
            });
            assert.notEqual(result.status, 0, `control "${label}": the suite passed on a copy without that rule`);
            assert.match(result.stdout + result.stderr, failure, `control "${label}": failed for the intended reason`);
            passed++;
        }
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
    return passed;
}

const count = process.env.IMAGE_TEXT_LOGIC_SKIP_CONTROLS === "1" ? 0 : controls();
console.log("test-image-text-logic: ok controls=" + count);
