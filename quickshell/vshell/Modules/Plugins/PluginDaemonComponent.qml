import QtQuick

// The one shell-owned instance of a plugin's daemon surface (VGS.qml creates
// it). A plugin whose widget fetches or polls keeps its timers, processes and
// fetched state here, and each bar widget, one per screen, reads them through
// a PluginDaemonLink. Run timers and processes only while `watched` is true,
// so a plugin that no bar shows fetches nothing.
PluginComponent {
    id: root

    // Links currently holding this instance. Only PluginDaemonLink changes it.
    property int viewers: 0
    readonly property bool watched: root.viewers > 0

    function claimView() {
        root.viewers += 1;
    }

    function releaseView() {
        if (root.viewers <= 0) {
            console.error("PluginDaemonComponent: " + root.pluginId + " released a view it never claimed");
            return;
        }
        root.viewers -= 1;
    }
}
