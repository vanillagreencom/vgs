// One on-demand owner for installed computer-family help. Families add one
// regular Markdown file; no topic or content is advertised before it ships.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const Tools = require("./Tools.js");
const ROOT = path.join(__dirname, "skills/computer");
const LIMIT = 8192;
function create(root = ROOT, browser = null) {
    const topics = Tools.TABLE.help.schema.properties.topic.enum.filter(topic => {
        try { return fs.lstatSync(path.join(root, topic + ".md")).isFile(); }
        catch (error) { if (error.code === "ENOENT") return false; throw error; }
    });
    return { commands: [], topics, timeoutMs: browser === null ? 2000 : browser.timeoutMs, cancellable: false,
        enableBrowser() {
            if (browser === null) throw new Error("help-browser-unavailable");
            if (!topics.includes("browser")) topics.push("browser");
        },
        start(call, done) {
            let fd;
            try {
                const topic = call.args.topic;
                if (!topics.includes(topic)) throw new Error("help-topic-unavailable");
                if (topic === "browser" && browser !== null) { browser.start(call, done); return; }
                fd = fs.openSync(path.join(root, topic + ".md"), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
                if (!fs.fstatSync(fd).isFile()) throw new Error("help-file-invalid");
                const buffer = Buffer.alloc(LIMIT + 1);
                const size = fs.readSync(fd, buffer);
                if (size > LIMIT) throw new Error("help-file-too-large");
                const content = new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size)).trim();
                if (content === "") throw new Error("help-file-empty");
                done({ outcome: "completed", content });
            } catch (error) { done({ outcome: "failed", content: "help-read:" + (error.code || error.message) }); }
            finally { if (fd !== undefined) fs.closeSync(fd); }
        } };
}
module.exports = { create };
