#!/usr/bin/env node
// status exits 0 with a manifest state value. verify exits 69 for missing
// Chrome, 1 for other failures. download is only called by the user's TUI.
"use strict";
const Browser = require("./Browser.js");
const command = process.argv[2];
if (process.argv.length !== 3 || !["status", "verify", "download"].includes(command)) {
    process.stderr.write("jarvis: browser-setup=arguments\n");
    process.exitCode = 2;
} else if (command === "status") {
    process.stdout.write(JSON.stringify(Browser.status(process.env)) + "\n");
} else {
    let owner;
    try {
        owner = Browser.create({ environment: process.env });
        if (command === "download") owner.download();
        else owner.verify();
    } catch (error) {
        process.stderr.write(error.message + "\n");
        process.exitCode = error.message === "jarvis: browser=missing" ? 69 : 1;
    } finally {
        if (owner !== undefined) {
            try { owner.close(); }
            catch (error) { process.stderr.write(error.message + "\n"); process.exitCode = 1; }
        }
    }
}
