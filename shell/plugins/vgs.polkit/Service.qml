import QtQuick
import "PolkitModel.js" as PolkitModel

// The polkit agent's service. The core builds the one agent while the
// plugin holds capability `polkit`; this service shows the prompt overlay
// while the agent holds an authentication request and takes it down when
// the request ends, and publishes whether polkitd accepted the agent. It
// holds no password and no flow state of its own.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    readonly property var agent: shell === null ? null : shell.polkit.agent
    readonly property bool active: agent !== null && agent.isActive
    // Published while the agent exists: the core destroys it as the plugin
    // is disabled, and a write then is refused as retired.
    readonly property var agentState: agent === null ? null : PolkitModel.agentStatus(shell.polkit.registered)
    // Whether the prompt shows, so each request summons it once and its end
    // hides it once.
    property bool shown: false

    onActiveChanged: route()
    onShellChanged: route()
    onAgentStateChanged: publish()

    // A request no prompt can answer is cancelled, so the application that
    // asked is denied at once instead of waiting on a dialog that never came.
    function route() {
        if (shell === null || active === shown) return;
        if (!active) {
            shown = false;
            shell.surfaces.hide("overlay");
            return;
        }
        const reply = shell.surfaces.summon("overlay", "{}");
        if (reply === "ok") {
            shown = true;
            return;
        }
        console.warn("polkit: summon " + reply + "; the request is cancelled");
        if (PolkitModel.cancellable(agent.flow)) agent.flow.cancelAuthenticationRequest();
    }

    // The state last published, so an unchanged state is written once.
    property var published: null

    function publish() {
        if (!PolkitModel.statusChanged(published, agentState)) return;
        const reply = shell.status.set("agent", agentState);
        if (reply === "ok") published = agentState;
        else console.warn("polkit: status " + reply);
    }
}
