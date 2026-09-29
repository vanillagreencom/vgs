import QtQuick

QtObject {
    id: model

    property string folder: ""
    property var nameFilters: []
    property bool showDirs: false
    property bool showDotAndDotDot: false
    property bool showHidden: false
    property var files: []
    readonly property int count: files.length

    signal modelReset()
    signal rowsInserted()
    signal rowsRemoved()

    function get(index, role) {
        if (role !== "filePath") return undefined;
        return files[index];
    }

    function setFiles(next, signalName) {
        files = next.slice();
        if (signalName === "drop") return;
        if (signalName === "insert") rowsInserted();
        else if (signalName === "remove") rowsRemoved();
        else modelReset();
    }

    Component.onCompleted: FolderListRegistry.add(model)
    Component.onDestruction: FolderListRegistry.remove(model)
}
