// Public verbs expose metadata only. Explicit Verify uses the outbound door.
"use strict";
const path = require("node:path");
const { Accounts } = require("./Accounts.js");
const { PROVIDERS, keyProvider } = require("../AccountProviders.js");

async function main() {
    const args = process.argv.slice(2);
    const state = path.join(process.env.XDG_STATE_HOME || path.join(process.env.HOME, ".local/state"), "vgs/jarvis");
    const snapshot = args[0] === "presence" && args.length === 2 ? JSON.parse(args[1]) : undefined;
    const judge = new Accounts(state, process.env, snapshot);
    let value;
    switch (args[0]) {
    case "presence":
        if (args.length !== 2) throw new Error("jarvis-accounts: arguments=presence");
        judge.discover();
        value = judge.status();
        break;
    case "list":
        if (args.length !== 1) throw new Error("jarvis-accounts: arguments=list");
        value = judge.discover();
        break;
    case "providers":
        if (args.length !== 2 || !["cli", "key"].includes(args[1])) throw new Error("jarvis-accounts: arguments=providers");
        value = PROVIDERS.filter(row => args[1] === "cli" ? row.kind === "cli" : keyProvider(row))
            .map(row => row.id);
        break;
    case "items":
        if (args.length !== 1) throw new Error("jarvis-accounts: arguments=items");
        value = judge.keyItems().map(item => ({ path: item.path, label: item.label, presence: item.presence }));
        break;
    case "add":
        if (args.length !== 4) throw new Error("jarvis-accounts: arguments=add");
        judge.add({ provider: args[1], directory: args[2], label: args[3] });
        value = { kind: "stored" };
        break;
    case "remember":
        if (args.length !== 4) throw new Error("jarvis-accounts: arguments=remember");
        judge.remember(args[1], args[2], args[3]);
        value = { kind: "stored" };
        break;
    case "verify":
        if (![3, 4].includes(args.length) || args[2] !== "user") throw new Error("jarvis-accounts: verify=explicit-user-required");
        judge.discover();
        value = await judge.verify(args[1], "user", undefined, args[3] || "");
        if (value.kind !== "verified") process.exitCode = 69;
        break;
    default: throw new Error("jarvis-accounts: arguments=verb");
    }
    process.stdout.write(JSON.stringify(value) + "\n");
}

main().catch(error => {
    const reason = /^(jarvis-accounts|jarvis-keys):/.test(error.message)
        ? error.message : "jarvis-accounts: operation=failed";
    process.stderr.write(reason + "\n");
    process.exitCode = 1;
});
