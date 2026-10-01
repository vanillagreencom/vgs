// The daemon's one executor registration seam. OWNERS names each Tools
// executor id with the module function that builds it. At first hello the
// daemon passes its router, its PATH lookup and its environment; the seam
// looks up each command that executor's Tools rows declare, never running
// one, and registers the executor with the commands found. An executor none
// of whose rows can run registers nothing. A missing command removes only its
// own rows from the router's offer. A command installed later is found at the
// daemon's next start.
"use strict";
const Tools = require("./Tools.js");
const Desktop = require("./Desktop.js");

const OWNERS = { clipboard: Desktop.create, media: Desktop.create, notify: Desktop.create };

/**
 * register(router, {find, environment, clock}) registers every OWNERS row it
 * can. find(command) answers the absolute file of an executable command on
 * the daemon's PATH, or null. Returns {close}, which ends every child the
 * registered executors still run; the router's own close does not.
 */
function register(router, { find, environment, clock }) {
    const owners = [];
    for (const [id, create] of Object.entries(OWNERS)) {
        const rows = Object.values(Tools.TABLE).filter(row => row.executor === id);
        const commands = new Map();
        for (const command of new Set(rows.map(row => row.command))) {
            if (command === null) continue;
            const file = find(command);
            if (file !== null) commands.set(command, file);
        }
        if (!rows.some(row => row.command === null || commands.has(row.command))) continue;
        const owner = create(id, { commands, environment, clock });
        router.register(id, owner.executor);
        owners.push(owner);
    }
    return Object.freeze({ close() { for (const owner of owners) owner.close(); } });
}

module.exports = { register };
