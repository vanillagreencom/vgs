#!/usr/bin/env node
// Synthetic TTS fixtures from v2-jarvis-plan.md §§ 5 and 9, 2026-09-30.
// This is text-only in-process evidence, not a speech-quality measurement.
"use strict";
const { assert, path, backend, world, control } = require("./fixtures/jarvis-voice/assertions.js");
const Speakable = require(path.join(backend, "Speakable.js"));
const fixtures = require("./fixtures/jarvis-voice/speakable.json");
function spoken(logic, row, chunks = [row.text]) {
    const stream = logic.create(row.language);
    const early = chunks.flatMap(chunk => stream.push(chunk));
    if (row.incremental) assert.deepEqual(early, row.sentences, row.name + " before finish");
    const output = early.concat(stream.finish());
    assert.deepEqual(output, row.sentences, row.name);
    if (row.counts !== undefined)
        for (const [kind, expected] of Object.entries(row.counts)) assert.equal(stream.counts()[kind], expected, row.name + " " + kind);
    if (row.violations === 0) assert.equal(Object.values(stream.counts()).reduce((a, b) => a + b, 0), 0, row.name + " measurement");
}
assert.equal(fixtures.length, 55, "sanitation coverage floor");
const long = { name: "bounded-sentences-after-comparison", language: "en", incremental: true,
    text: "If a<b then stop. " + "Next sentence. ".repeat(300),
    sentences: ["If a b then stop.", ...Array(300).fill("Next sentence.")] };
assert.ok(long.text.length > Speakable.limits.token, "aggregate reaches the old held-candidate overflow");
for (const row of [...fixtures, long]) {
    spoken(Speakable, row);
    spoken(Speakable, row, row.text.split(""));
    for (let cut = 0; cut <= row.text.length; cut++)
        spoken(Speakable, row, [row.text.slice(0, cut), row.text.slice(cut)]);
}
const stream = Speakable.create("en");
assert.deepEqual(stream.push("First. "), ["First."], "deliver before brain EOF");
assert.deepEqual(stream.push("Second"), []);
assert.deepEqual(stream.finish(), ["Second"]);
assert.throws(() => stream.push("Later"), { message: "jarvis: speakable=stream-closed" });
assert.throws(() => stream.finish(), { message: "jarvis: speakable=stream-closed" });
const counts = Speakable.violations("**At** 2 kg see https://example.com. `code` /tmp/file.", "en");
assert.deepEqual(counts, { markdown: 4, code: 1, url: 1, path: 1, symbol: 0, number: 1, unit: 1, date: 0, time: 0 });
assert.deepEqual(Speakable.violations("All done.", "es"),
    { markdown: 0, code: 0, url: 0, path: 0, symbol: 0, number: 0, unit: 0, date: 0, time: 0 });
assert.equal(Object.isFrozen(counts), true);
const overflow = [
    ["chunk", "a".repeat(16385)], ["token", "https://" + "a".repeat(4090)],
    ["sentence", "a ".repeat(2049)], ["output", ("4".repeat(4000) + ". ").repeat(4)]
];
function refused(logic, [cause, input]) {
    const stream = logic.create("es");
    assert.throws(() => stream.push(input), { message: "jarvis: speakable=" + cause + "-overflow" });
    assert.throws(() => stream.finish(), { message: "jarvis: speakable=stream-failed" });
}
for (const row of overflow) refused(Speakable, row);
assert.equal(Speakable.create("en").push("a".repeat(4096)).length, 0);
assert.equal(Speakable.create("en").push("`" + "x".repeat(16000)).length, 0, "code body is discarded, not stored");
assert.throws(() => Speakable.create("en").push(null), { message: "jarvis: speakable=chunk-type" });

let controls = 0;
world("js", root => {
    const rows = [
        ["kept-url", 'plain(siteName(address) + trailing, output);', 'plain(address + trailing, output);',
            logic => spoken(logic, fixtures.find(row => row.name === "url"))],
        ["kept-code", 'else pending = pending.slice(1);', 'else { plain(pending[0], output); pending = pending.slice(1); }',
            logic => spoken(logic, fixtures.find(row => row.name === "fenced-code"))],
        ["markdown-count", 'note("markdown"); pending = pending.slice(1); plain(" ", output);',
            'if (false) note("markdown"); pending = pending.slice(1); plain(" ", output);',
            logic => assert.equal(logic.violations("**Ready**.", "en").markdown, 4)],
        ["kept-path", 'note("path"); plain(" " + trailing, output);',
            'note("path"); plain(pending.slice(0, length), output);',
            logic => spoken(logic, fixtures.find(row => row.name === "paths"))],
        ["comparison-prose", 'plain("<", output); pending = pending.slice(1); continue;',
            'plain("<", output); mode = "code"; fence = ">"; pending = pending.slice(1); continue;',
            logic => spoken(logic, fixtures.find(row => row.name === "comparison-spaced"))],
        ["unterminated-prose", 'if (!final && tag.kind === "pending") return;',
            'if (tag.kind === "pending") { if (final) pending = ""; return; }',
            logic => spoken(logic, fixtures.find(row => row.name === "unterminated-short-candidate"))],
        ["html-prefix-viability", 'if (space === null) return { kind: "prose" };',
            'if (space === null) return { kind: "pending" };',
            logic => spoken(logic, fixtures.find(row => row.name === "comparison-incremental"))],
        ["html-removal", 'if (tag.kind === "tag")', 'if (false)',
            logic => spoken(logic, fixtures.find(row => row.name === "html-attributes"))],
        ["path-boundary", 'pathBoundary && /', 'true && /',
            logic => spoken(logic, fixtures.find(row => row.name === "rates-en"))],
        ["path-punctuation", '!/[\\p{L}\\p{N}]$/u.test(sentence)', '/\\s$/u.test(sentence)',
            logic => spoken(logic, fixtures.find(row => row.name === "path-punctuation"))],
        ["html-path-separator", 'pending = pending.slice(tag.length); plain(" ", output);',
            'pending = pending.slice(tag.length);',
            logic => spoken(logic, fixtures.find(row => row.name === "path-html-separator"))],
        ["spanish-punctuation", "!?¿¡;", "!?;",
            logic => spoken(logic, fixtures.find(row => row.name === "punctuation-es"))],
        ["streaming-cut", 'emit(sentence.slice(0, end), output);', 'emit("", output);',
            logic => spoken(logic, fixtures.find(row => row.name === "markdown"))],
        ["violation-count", 'counts[kind]++;', 'counts[kind] += 0;',
            logic => assert.equal(logic.violations("https://example.com", "en").url, 1)],
        ["chunk-type", 'typeof chunk !== "string"', 'false',
            logic => assert.throws(() => logic.create("en").push(null), { message: "jarvis: speakable=chunk-type" })],
        ["lifetime", 'lifecycle !== "open"', 'false', logic => {
            const stream = logic.create("en"); stream.finish();
            assert.throws(() => stream.push("Later"), { message: "jarvis: speakable=stream-closed" });
        }]
    ];
    for (const [name, needle, replacement, check] of rows) {
        control(root, name, "Speakable.js", needle, replacement, check); controls++;
    }
    for (const row of overflow) {
        const [name] = row;
        const needle = name === "output" ? 'output.reduce((size, item) => size + item.length, 0) > LIMITS.output'
            : 'bound(' + (name === "token" ? "pending" : name) + ', LIMITS.' + name + ', "' + name + '");';
        control(root, name + "-bound", "Speakable.js", needle, name === "output" ? "false" : ";",
            logic => refused(logic, row)); controls++;
    }
});
console.log("test-jarvis-speakable: ok fixtures=" + fixtures.length + " controls=" + controls);
