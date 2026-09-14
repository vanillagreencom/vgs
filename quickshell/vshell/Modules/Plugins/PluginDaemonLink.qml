import QtQuick

// A per-screen widget's hold on its plugin's PluginDaemonComponent. `daemon` is
// the shell-owned instance, or null until the daemon Instantiator registers it.
// While `watching`, the link counts as one of that instance's viewers; a reload
// registers a new instance, and the hold moves to it.
QtObject {
    id: link

    property var pluginService: null
    property string pluginId: ""
    // False releases the hold but keeps `daemon`, for a widget that exists but
    // is not on screen.
    property bool watching: true

    readonly property var daemon: link.pluginService && link.pluginId !== ""
        ? (link.pluginService.daemonInstances[link.pluginId] || null) : null

    // The engine clears this when the held instance is destroyed, so a reload
    // never calls into a deleted daemon.
    property QtObject _held: null

    // BEGIN DAEMON HOLD
    // Hold the daemon while watching and nothing otherwise. A changed target is
    // released before the new one is claimed, and an unchanged target is left
    // alone, so each link counts at most once on at most one instance.
    function syncHold(l) {
        const next = l.watching ? l.daemon : null;
        if (next === l._held)
            return;
        if (l._held)
            l._held.releaseView();
        l._held = next;
        if (next)
            next.claimView();
    }

    function dropHold(l) {
        if (l._held)
            l._held.releaseView();
        l._held = null;
    }
    // END DAEMON HOLD

    onDaemonChanged: link.syncHold(link)
    onWatchingChanged: link.syncHold(link)
    Component.onCompleted: link.syncHold(link)
    Component.onDestruction: link.dropHold(link)
}
