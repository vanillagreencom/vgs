#!/usr/bin/env node
// Converts bin/check probe files into the status.json snapshot. It loads the
// plugin's pure UpdatesLogic.js through the core qml-library loader so the
// script and QML use the same judge.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

function usage(first) {
  process.stderr.write("updates-normalize: refused: " + first + "\n");
  process.exit(2);
}

if (process.argv.length !== 6) usage("arguments=want-loader-logic-state-prefix");
const loaderPath = process.argv[2];
const logicPath = process.argv[3];
const stateDir = process.argv[4];
const prefix = process.argv[5];
const { load } = require(loaderPath);
const logic = load(logicPath);

function read(name) {
  return {
    status: Number(fs.readFileSync(path.join(stateDir, `.${name}.${prefix}.status`), "utf8")),
    stdout: fs.readFileSync(path.join(stateDir, `.${name}.${prefix}.out`), "utf8"),
    stderr: fs.readFileSync(path.join(stateDir, `.${name}.${prefix}.err`), "utf8")
  };
}

const probes = { pkg: read("pkg"), self: read("self"), plugins: read("plugins"), themes: read("themes") };
process.stdout.write(JSON.stringify(logic.normalizeSnapshot(probes, Date.now())) + "\n");
