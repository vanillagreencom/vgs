// Session guidance for the J33 chained engine and J37 duplex delegation.
// compose(engine, brainClass, language) returns { instructions, layers,
// afterToolResult }. Engines are "chained" or "duplex"; classes are "duplex"
// (the voice model), "text" or "local" (a brain). The local chained consumer
// appends afterToolResult as instructions after EACH tool result.
// Read failures and bounds throw keyed errors. No cache or session store.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { languageCode } = require("./SpeechLanguage.js");
const MAX_LAYER_BYTES = 8192;
const MAX_COMPOSE_BYTES = 32768;
const ROOT = path.join(__dirname, "skills/voice");

function layer(name) {
    const file = path.join(ROOT, name);
    let fd;
    try {
        fd = fs.openSync(file, "r");
        const buffer = Buffer.alloc(MAX_LAYER_BYTES + 1);
        let size = 0;
        while (size < buffer.length) {
            const read = fs.readSync(fd, buffer, size, buffer.length - size, null);
            if (read === 0) break;
            size += read;
        }
        if (size > MAX_LAYER_BYTES) throw new Error("layer-too-large");
        const text = new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size)).trim();
        if (text === "") throw new Error("layer-empty");
        return text;
    } catch (error) {
        throw new Error("jarvis: guidance=layer file=" + name + " cause=" + (error.code || error.message));
    } finally {
        if (fd !== undefined) fs.closeSync(fd);
    }
}

/** Compose only the layers assigned to this consumer by the voice contract. */
function compose(engine, brainClass, language) {
    if (engine !== "chained" && engine !== "duplex") throw new Error("jarvis: guidance=engine");
    if (!["duplex", "text", "local"].includes(brainClass)) throw new Error("jarvis: guidance=class");
    if (engine === "chained" && brainClass === "duplex") throw new Error("jarvis: guidance=consumer");
    const code = languageCode(language);
    let names;
    if (engine === "duplex") {
        names = brainClass === "duplex"
            ? ["core-short.md", "speech.md", "turns.md", "class/duplex.md"]
            : ["core.md", "speech.md", "actions.md"];
    } else {
        names = ["core.md", "speech.md", "turns.md", "actions.md"];
        if (brainClass === "local") names.push("class/local.md");
        names.push("lang/" + code + ".md");
    }
    const content = names.map(layer);
    const instructions = content.join("\n\n");
    if (Buffer.byteLength(instructions) > MAX_COMPOSE_BYTES) throw new Error("jarvis: guidance=compose-too-large");
    // The same core rule reaches the model again, not a second spelling of it.
    const afterToolResult = engine === "chained" && brainClass === "local" ? content[0] + "\n\n" + content[4] : null;
    return Object.freeze({ instructions, layers: Object.freeze(names), afterToolResult });
}

module.exports = { compose };
