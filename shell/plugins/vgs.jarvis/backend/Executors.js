// The daemon's one executor registration seam. OWNERS names each Tools
// executor id with the module that builds it; the module's TOOLS lists the
// Tools rows it runs. At first hello the daemon passes its router, its PATH
// lookup and its environment; the seam looks up each command those rows
// declare, never running one, and registers the executor with the commands
// found. A row its owner does not run stays unoffered. An executor none of
// whose rows can run registers nothing. A missing command removes only its
// own rows from the router's offer. A command installed later is found at the
// daemon's next start.
"use strict";
const Tools = require("./Tools.js");
const Desktop = require("./Desktop.js");

const OWNERS = { clipboard: Desktop, media: Desktop, notify: Desktop };

/**
 * register(router, {find, environment, clock}) registers every OWNERS row it
 * can. find(command) answers the absolute file of an executable command on
 * the daemon's PATH, or null. A running command ends through the router's
 * cancel, which Session requests on stop, expiry and lease end.
 */
function register(router, { find, environment, clock }) {
    for (const [id, owner] of Object.entries(OWNERS)) {
        const rows = owner.TOOLS.map(tool => Tools.TABLE[tool]).filter(row => row.executor === id);
        const commands = new Map();
        for (const command of new Set(rows.map(row => row.command))) {
            if (command === null) continue;
            const file = find(command);
            if (file !== null) commands.set(command, file);
        }
        if (!rows.some(row => row.command === null || commands.has(row.command))) continue;
        router.register(id, owner.create(id, { commands, environment, clock }));
    }
}

module.exports = { register };
