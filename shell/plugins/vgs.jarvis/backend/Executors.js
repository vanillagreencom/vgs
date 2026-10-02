// The daemon's one executor registration seam. The desktop session installs
// its shared lifetime, each command executor is built from its TOOLS rows,
// and the vision executor installs on the session's reader. Only the session
// owner probes Hyprland; optional commands use lookup without exec.
"use strict";
const Tools = require("./Tools.js");
const Desktop = require("./Desktop.js");
const DesktopSession = require("./DesktopSession.js");
const Vision = require("./Vision.js");

const OWNERS = { clipboard: Desktop, media: Desktop, notify: Desktop };

/**
 * register(router, {find, environment, clock, desktop, vision}) registers
 * every executor it can. find(command) answers the absolute file of an
 * executable command on the daemon's PATH, or null. A running command ends
 * through the router's cancel, which Session requests on stop, expiry and
 * lease end. desktop holds DesktopSession.install's options and vision
 * Vision.install's own. close releases installed lifetimes after the router
 * closes; command cancellation stays with the router.
 */
function register(router, { find, environment, clock, desktop, vision }) {
    const session = DesktopSession.install({ router, ...desktop });
    const lifetimes = [session];
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
    // Vision reads Hyprland through the session's one reader, after its probe.
    lifetimes.push(Vision.install({ router, session, find, environment, clock,
        onScreen: desktop.Dispatch.onScreen, ...vision }));
    return { close() { for (const lifetime of lifetimes) lifetime.close(); } };
}

module.exports = { register };
