import QtQuick

// __NAME__ service. Put required watchers and subprocesses inside this
// item so disabling the plugin releases them with the entry point. A value
// the plugin's widgets or Settings page show is published from here with
// shell.status.set, declared in the manifest's `status`.
Item {
    property var shell: null
}
