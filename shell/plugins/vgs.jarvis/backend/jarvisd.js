#!/usr/bin/env node
// jarvisd --tree ABSOLUTE_VGS_TREE
// Stdin is the service's lease. EOF exits 0; a partial line or a refused
// message exits 65. Node below 22 exits 78. Stdout carries v1 status/state
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
    const Session = Protocol.Session;
    const { SessionRunner, unavailable } = require("./session-runner.js");
    const decoder = new StringDecoder("utf8");
    let tail = "";
    let context = null;
    let ending = false;
    let seq = 0;

    function write(message) {
        const wire = JSON.stringify(message);
        Protocol.accept(wire, "daemon");
        if (!process.stdout.write(wire + "\n")) process.stdin.pause();
    }
    const runner = new SessionRunner(Session, unavailable(), {
        now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer)
    }, (state, phase) => {
        if (!ending && context !== null) write({ v: 1, type: "state", gen: state.gen,
            revision: context.revision, seq: ++seq, state, phase });
    });

    function read(chunk) {
        if (ending) return;
        try {
            const framed = Protocol.feed(tail, chunk);
            tail = framed.tail;
            for (const line of framed.lines) {
                const message = Protocol.accept(line, "shell");
                context = message;
                write({ v: 1, type: "status", gen: runner.state.gen, revision: context.revision,
                    daemon: context.locked ? "locked" : "ready" });
                // No adapter/configuration/indicator exists yet. A healthy
                // child is not permission to capture or start a tool.
                runner.dispatch({ type: "snapshot", locked: context.locked,
                    configured: false, echoCancel: false, settings: context.settings });
            }
        } catch (error) {
            ending = true;
            runner.close();
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
        runner.close();
        if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");
        // No child or handle holds the process alive after lease loss.
    });
}
