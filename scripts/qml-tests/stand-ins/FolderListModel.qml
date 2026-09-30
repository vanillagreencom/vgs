import QtQuick

// Stands in for Qt.labs.folderlistmodel's FolderListModel, whose real
// watcher cannot be forced to drop one change on demand. The TUI records
// test drives the listed paths by hand and can choose whether a reset,
// insert, removal or no signal reaches the owner.
Item {
    id: model
    enum Status { Null, Loading, Ready }

    property string folder: ""
    property int status: FolderListModel.Ready
    property string pendingFolder: ""
    property var nameFilters: []
    property bool showDirs: false
    property bool showFiles: true
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
        status = FolderListModel.Ready;
        if (signalName === "drop") return;
        if (signalName === "insert") rowsInserted();
        else if (signalName === "remove") rowsRemoved();
        else modelReset();
    }

    onFolderChanged: {
        pendingFolder = String(folder);
        status = FolderListModel.Loading;
        settle.restart();
    }

    Timer {
        id: settle
        interval: 1
        onTriggered: model.status = model.pendingFolder.indexOf("nonexistent-") === -1 ? FolderListModel.Ready : FolderListModel.Null
    }

    Component.onCompleted: FolderListRegistry.add(model)
    Component.onDestruction: FolderListRegistry.remove(model)
}
