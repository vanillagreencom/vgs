.pragma library

// Launcher entries for the Dev tools section, built from
// config/vshell/dev-tools.json: one "Launch" per coding agent and one
// "Install" per language environment. The catalog is the only list.
function itemsFromCatalog(raw) {
    const data = JSON.parse(raw || "{}");
    const out = [];
    for (const agent of data.agents || []) {
        out.push({
            category: "dev",
            title: agent.name,
            subtitle: "Coding agent, " + agent.command,
            icon: "\uf544",
            keywords: ["agent", "ai", "code", agent.id, agent.command],
            argv: ["{vshell}", "agent", "launch", agent.id]
        });
    }
    for (const env of data.envs || []) {
        out.push({
            category: "dev",
            title: env.name,
            subtitle: env.installer === "rustup" ? "Language environment, install with rustup" : "Language environment, install with mise",
            icon: "\uf121",
            keywords: ["install", "language", "environment", "dev", env.id],
            argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "dev-env", "install", env.id]
        });
    }
    return out;
}
