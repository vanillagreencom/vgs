// The daemon's one executor registration seam. An owner installs its shared
// lifetime or builds one command executor from its TOOLS rows. Only the
// session owner probes Hyprland; optional commands use lookup without exec.
"use strict";
const Tools = require("./Tools.js");
const Desktop = require("./Desktop.js");
const DesktopSession = require("./DesktopSession.js");

const OWNERS = { desktop: DesktopSession, clipboard: Desktop, media: Desktop, notify: Desktop };

/**
 * register(router, {find, environment, clock, desktop}) registers every OWNERS row it
 * can. find(command) answers the absolute file of an executable command on
 * the daemon's PATH, or null. A running command ends through the router's
 * cancel, which Session requests on stop, expiry and lease end. desktop holds
 * DesktopSession.install's options. close releases installed shared lifetimes
 * after the router closes; command cancellation stays with the router.
 */
function register(router, { find, environment, clock, desktop }) {
    const lifetimes = [];
    for (const [id, owner] of Object.entries(OWNERS)) {
        if (owner.install !== undefined) {
            lifetimes.push(owner.install({ router, ...desktop }));
            continue;
        }
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
    return { close() { for (const lifetime of lifetimes) lifetime.close(); } };
}

module.exports = { register };
