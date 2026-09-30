// Only add-key and presence are public CLI verbs. A key never reaches stdout.
"use strict";
const path = require("node:path");
const { Secrets, ownReference } = require("./Secrets.js");

function main() {
    const directory = path.join(process.env.XDG_STATE_HOME || path.join(process.env.HOME, ".local/state"), "vgs/jarvis");
    const store = new Secrets(directory, process.env);
    switch (process.argv[2]) {
    case "presence":
        if (process.argv.length !== 3) throw new Error("jarvis-keys: arguments=verb");
        process.stdout.write(JSON.stringify(store.rows()) + "\n");
        break;
    case "add-key": {
        if (process.argv.length !== 6) throw new Error("jarvis-keys: arguments=metadata");
        const [provider, account, origin] = process.argv.slice(3);
        const ref = ownReference(provider, account, origin);
        store.addKey(ref);
        process.stdout.write("jarvis-keys: stored=libsecret\n");
        break;
    }
    default: throw new Error("jarvis-keys: arguments=verb");
    }
}
try { main(); }
catch (error) {
    const reason = error.message.startsWith("jarvis-keys:") ? error.message : "jarvis-keys: operation=failed";
    process.stderr.write(reason + "\n");
    process.exitCode = 1;
}
