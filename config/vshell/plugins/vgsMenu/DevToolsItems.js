.pragma library

// Build launcher entries from `vshell agent list` and `vshell dev-env list`.
// Those already drop what this machine's architecture cannot install, so the
// tiles cannot disagree with the settings page or offer an install that has no
// asset to download. Group ordering keeps category entries before agents, apps
// and environments when no query ranks them.
function iconFields(spec) {
    const match = /^(nerd|brand):([0-9a-f]+)$/i.exec(spec || "");
    if (!match)
        return {};
    return { icon: String.fromCodePoint(parseInt(match[2], 16)), iconFont: match[1] === "brand" ? "brand" : "nerd" };
}

function launchableEntry(entry, tag, group, keywords) {
    return Object.assign({
        category: "dev",
        title: entry.name,
        subtitle: entry.command,
        tag: tag,
        group: group,
        devId: entry.id,
        devKind: "agent",
        iconColor: entry.color || "",
        keywords: keywords.concat([entry.id, entry.command]),
        argv: ["{vshell}", "agent", "launch", entry.id]
    }, iconFields(entry.icon));
}

function itemsFromLists(agentList, envList) {
    const agents = JSON.parse(agentList || "{}");
    const data = JSON.parse(envList || "{}");
    const out = [];
    for (const agent of agents.agents || [])
        out.push(launchableEntry(agent, "Agent", 1, ["agent", "ai", "code"]));
    // Apps launch through the same command as agents, so devKind stays "agent";
    // the tag is what tells a reader which of the two they are looking at.
    for (const app of agents.apps || [])
        out.push(launchableEntry(app, "App", 2, ["app", "dev", "tool"]));
    for (const env of data.envs || []) {
        out.push(Object.assign({
            category: "dev",
            title: env.name,
            subtitle: env.installer === "rustup" ? "install with rustup" : "install with mise",
            tag: "Environment",
            group: 3,
            devId: env.id,
            devKind: "environment",
            iconColor: env.color || "",
            keywords: ["install", "language", "environment", "dev", env.id],
            argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "dev-env", "install", env.id]
        }, iconFields(env.icon)));
    }
    return out;
}
