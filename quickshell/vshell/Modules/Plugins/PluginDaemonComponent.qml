import QtQuick

// The one shell-owned instance of a plugin's daemon surface (VGS.qml creates
// it). A plugin that moves its fetch here keeps its timers, processes and
// fetched state in this instance, and each bar widget, one per screen, reads
// them through a PluginDaemonLink. Run timers and processes only while
// `watched` is true, so a plugin with no watching widget fetches nothing.
PluginComponent {
    id: root

    // Links currently holding this instance. Only PluginDaemonLink changes it.
    property int viewers: 0
    readonly property bool watched: root.isWatched(root.viewers)

    // BEGIN DAEMON COUNT
    // A release with no claim outstanding leaves the count at zero and returns
    // false, so the caller can report it.
    function claim(d) {
        d.viewers += 1;
    }

    function release(d) {
        if (d.viewers <= 0)
            return false;
        d.viewers -= 1;
        return true;
    }

    function isWatched(viewers) {
        return viewers > 0;
    }
    // END DAEMON COUNT

    function claimView() {
        root.claim(root);
    }

    function releaseView() {
        if (!root.release(root))
            console.error("PluginDaemonComponent: " + root.pluginId + " released a view it never claimed");
    }
}
