// Test-only service instrumentation. The shared J09 helper runs directly.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

function service(sourceTree, tree, root) {
    fs.mkdirSync(path.join(root, "standins"), { recursive: true });
    const launcher = path.join(sourceTree, "scripts/lib/jarvis-env.sh");
    const lease = path.join(root, "lease.sh");
    // Bash gives an asynchronous command /dev/null on stdin. J09 starts
    // its namespace supervisor asynchronously, so carry the service pipe
    // as a descriptor and restore it only inside that namespace.
    fs.writeFileSync(lease, '#!/bin/bash\nset -euo pipefail\nexec 3<&0\n' +
        'exec bash "$1" "$2" -- bash -c \'exec node "$@" <&3 3<&-\' jarvis-lease "$3" --tree "$4"\n',
        { mode: 0o700 });
    const file = path.join(tree, "shell/plugins/vgs.jarvis/Service.qml");
    if (!fs.existsSync(file)) return;
    const source = fs.readFileSync(file, "utf8");
    const needle = 'command: ["node", root.daemon, "--tree", Quickshell.shellDir + "/.."]';
    assert.equal(source.split(needle).length - 1, 1, "Jarvis command instrumentation match");
    const replacement = 'command: ["bash", ' + JSON.stringify(lease) + ', ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', root.daemon, Quickshell.shellDir + "/.."]';
    fs.writeFileSync(file, source.replace(needle, replacement));
}

if (require.main === module) {
    assert.equal(process.argv.length, 5);
    service(...process.argv.slice(2));
}
