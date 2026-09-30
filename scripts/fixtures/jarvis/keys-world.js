// Synthetic SearchItems fixture: Secret Service 0.2, SearchItems's two
// object-path arrays; busctl --json=short from systemd's call interface.
// https://specifications.freedesktop.org/secret-service/0.2/org.freedesktop.Secret.Service.html
// Fixture authored 2026-09-30. No vendor account, auth or credential file.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const ref = { provider: "fixture", account: "test", origin: "https://fixture.invalid",
    attributes: { service: "vgs-jarvis", provider: "fixture", account: "test", origin: "https://fixture.invalid" } };

function standins(directory) {
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(path.join(directory, "busctl"), `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
fs.appendFileSync(path.join(process.env.XDG_STATE_HOME, "bus-calls"), JSON.stringify(args) + "\\n");
if (args[0] !== "--user" || !args.includes("--auto-start=no") ||
    !args.includes("--allow-interactive-authorization=no") || !args.includes("SearchItems"))
    process.exit(9);
let mode = "present";
try { mode = fs.readFileSync(path.join(process.env.XDG_STATE_HOME, "bus-mode"), "utf8").trim(); }
catch (error) { if (error.code !== "ENOENT") throw error; }
if (mode === "failed") { console.error("test-key-must-stay-private"); process.exit(7); }
if (mode === "junk") { console.log('{"type":"s","data":"test-key-must-stay-private"}'); process.exit(0); }
const item = "/org/freedesktop/secrets/collection/test/item";
console.log(JSON.stringify({ type: "aoao", data: [mode === "present" ? [item] : [], mode === "locked" ? [item] : []] }));
`, { mode: 0o700 });
    fs.writeFileSync(path.join(directory, "secret-tool"), `#!/usr/bin/env python3
import getpass, json, os, sys
from pathlib import Path
root = Path(os.environ["XDG_STATE_HOME"])
args = sys.argv[1:]
with (root / "secret-calls").open("a") as output:
    output.write(json.dumps({"argv": args, "env": dict(os.environ)}) + "\\n")
if args[0] == "lookup":
    sys.stdout.write("test-key-must-stay-private")
elif args[0] == "store":
    if not sys.stdin.isatty():
        sys.exit(8)
    key = getpass.getpass("Password: ")
    if key != "test-key-must-stay-private":
        sys.exit(9)
    if (root / "store-fail").exists():
        print(key, file=sys.stderr)
        print(key)
        sys.exit(6)
    print(key)  # A noisy storage helper must still expose no value.
else:
    print("test-key-must-stay-private")
    print("test-key-must-stay-private", file=sys.stderr)
    sys.exit(10)
`, { mode: 0o700 });
    fs.writeFileSync(path.join(directory, "gum"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
}

module.exports = { ref, standins };
if (require.main === module) {
    const directory = path.join(process.env.XDG_STATE_HOME, "vgs/jarvis");
    fs.mkdirSync(directory, { recursive: true });
    const mode = process.argv[3] ? fs.readFileSync(process.argv[3], "utf8").trim() : "present";
    fs.writeFileSync(path.join(directory, "keys.json"), mode === "probe-failed" ? "junk" : JSON.stringify([ref]));
    fs.writeFileSync(path.join(process.env.XDG_STATE_HOME, "bus-mode"), mode);
    const env = {};
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) env[name] = process.env[name];
    const result = cp.spawnSync("node", [process.argv[2], "presence"], { env, stdio: "inherit" });
    process.exit(result.status ?? 1);
}
