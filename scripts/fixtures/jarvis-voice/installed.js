// Test-only consumer of the installed voice APIs. Argument: runtime tree.
// Run with an empty environment. No engine, process, audio or network API.
"use strict";
const assert = require("node:assert/strict");
const path = require("node:path");
const backend = path.join(process.argv[2], "shell/plugins/vgs.jarvis/backend");
const Guidance = require(path.join(backend, "Guidance.js"));
const Speakable = require(path.join(backend, "Speakable.js"));
require(path.join(backend, "ComputerHelp.js")).create().start({ id: "help", args: { topic: "shell" } }, result => {
    assert.equal(result.outcome, "completed");
    assert.equal(result.content, require("node:fs").readFileSync(path.join(backend, "skills/computer/shell.md"), "utf8").trim());
});
for (const language of ["en", "es"]) {
    for (const [engine, brain] of [["duplex", "duplex"], ["duplex", "text"], ["duplex", "local"], ["chained", "text"], ["chained", "local"]])
        assert.ok(Guidance.compose(engine, brain, language).instructions.length > 0);
    const stream = Speakable.create(language);
    assert.deepEqual(stream.push("https://example.com. ").concat(stream.finish()), ["example."]);
    assert.equal(Speakable.violations("https://example.com.", language).url, 1);
}
console.log("jarvis-voice-installed=ok");
