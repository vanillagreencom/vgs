.pragma library

// Launcher entries for the Dev tools section, built from
// config/vshell/dev-tools.json: one entry per coding agent (tag harness,
// listed first) and one per language environment (tag environment). The
// catalog is the only list; `group` orders them when no query ranks them.
function iconFields(spec) {
    const match = /^(nerd|brand):([0-9a-f]+)$/i.exec(spec || "");
    if (!match)
        return {};
    return { icon: String.fromCodePoint(parseInt(match[2], 16)), iconFont: match[1] === "brand" ? "brand" : "nerd" };
}

function itemsFromCatalog(raw) {
    const data = JSON.parse(raw || "{}");
    const out = [];
    for (const agent of data.agents || []) {
        out.push({
            category: "dev",
            title: agent.name,
            subtitle: agent.kind === "server" ? agent.command + ", server only: opens in the browser (no app)" : agent.command,
            tag: "harness",
            group: 0,
            iconColor: agent.color || "",
            ...iconFields(agent.icon),
            keywords: ["agent", "ai", "code", agent.id, agent.command],
            argv: ["{vshell}", "agent", "launch", agent.id]
        });
    }
    for (const env of data.envs || []) {
        out.push({
            category: "dev",
            title: env.name,
            subtitle: env.installer === "rustup" ? "install with rustup" : "install with mise",
            tag: "environment",
            group: 1,
            iconColor: env.color || "",
            ...iconFields(env.icon),
            keywords: ["install", "language", "environment", "dev", env.id],
            argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "dev-env", "install", env.id]
        });
    }
    return out;
}
