.pragma library

// Launcher entries for the Dev tools section, built from
// config/vshell/dev-tools.json: one entry per coding agent (tag harness,
// listed first) and one per language environment (tag environment). The
// catalog is the only list; `group` orders them when no query ranks them.
function itemsFromCatalog(raw) {
    const data = JSON.parse(raw || "{}");
    const out = [];
    for (const agent of data.agents || []) {
        out.push({
            category: "dev",
            title: agent.name,
            subtitle: agent.command,
            tag: "harness",
            group: 0,
            icon: "\uf544",
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
            icon: "\uf121",
            keywords: ["install", "language", "environment", "dev", env.id],
            argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "dev-env", "install", env.id]
        });
    }
    return out;
}
