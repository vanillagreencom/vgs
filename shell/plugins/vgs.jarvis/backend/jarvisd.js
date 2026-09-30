#!/usr/bin/env node
// jarvisd --tree ABSOLUTE_VGS_TREE
// Stdin is the service's lease. EOF exits 0; a partial line or a refused
// message exits 65. Node below 22 exits 78. Stdout carries only v1 status
// messages judged by JarvisProtocol; stderr carries keyed jarvis: failures.
// This skeleton opens no file store, socket, account or audio device.
"use strict";
const path = require("node:path");
const { StringDecoder } = require("node:string_decoder");

function refuse(code, reason) {
    process.stderr.write(reason + "\n");
    process.exitCode = code;
    process.stdin.destroy();
}

if (Number(process.versions.node.split(".")[0]) < 22) {
    refuse(78, "jarvis: node=" + process.versions.node + " need=22");
} else if (process.argv.length !== 4 || process.argv[2] !== "--tree" || !path.isAbsolute(process.argv[3])) {
    refuse(2, "jarvis: arguments=expected-tree");
} else {
    const { load } = require(path.join(process.argv[3], "bin/lib/qml-library.js"));
    const Protocol = load(path.join(__dirname, "../JarvisProtocol.js"));
    const decoder = new StringDecoder("utf8");
    let tail = "";
    let context = null;
    let ending = false;

    function read(chunk) {
        if (ending) return;
        try {
            const framed = Protocol.feed(tail, chunk);
            tail = framed.tail;
            for (const line of framed.lines) {
                const message = Protocol.accept(line, "shell");
                // Hello replaces the service-owned snapshot, including lock
                // observation. No conversation or Session reducer exists yet.
                context = message;
                const reply = { v: 1, type: "status", gen: context.gen, revision: context.revision,
                    daemon: context.locked ? "locked" : "ready" };
                const wire = JSON.stringify(reply);
                Protocol.accept(wire, "daemon");
                if (!process.stdout.write(wire + "\n")) process.stdin.pause();
            }
        } catch (error) {
            ending = true;
            refuse(65, error.message);
        }
    }
    process.stdout.on("drain", () => { if (!ending) process.stdin.resume(); });
    process.stdout.on("error", error => { ending = true; refuse(74, "jarvis: stdout=" + error.code); });
    process.stdin.on("error", error => { ending = true; refuse(74, "jarvis: stdin=" + error.code); });
    process.stdin.on("data", chunk => read(decoder.write(chunk)));
    process.stdin.on("end", () => {
        read(decoder.end());
        if (ending) return;
        ending = true;
        if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");
        // No child or handle holds the process alive after lease loss.
    });
}
