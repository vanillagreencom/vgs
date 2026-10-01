import QtQuick

// Stands in for Qt.labs.folderlistmodel's FolderListModel, whose real
// watcher cannot be forced to drop one change on demand. A missing folder
// sends Null during the setter. An existing folder keeps the old status,
// then reports Loading and Ready later. A QML property still announces
// `folder` on every write, unlike Qt's missing-folder path; PathField's
// missing judge also reads `status`, so it does not depend on that gap.
// The TUI records test drives the listed paths by hand and can choose
// whether a reset, insert, removal or no signal reaches the owner.
Item {
    id: model
    enum Status { Null, Loading, Ready }

    property string folder: ""
    property int status: FolderListModel.Ready
    property string pendingFolder: ""
    property int pendingStep: 0
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
        if (pendingFolder.indexOf("nonexistent-") !== -1) {
            settle.stop();
            files = [];
            status = FolderListModel.Null;
            modelReset();
            return;
        }
        pendingStep = 0;
        settle.restart();
    }

    Timer {
        id: settle
        interval: 1
        repeat: true
        onTriggered: {
            if (model.pendingStep === 0) {
                model.pendingStep = 1;
                model.status = FolderListModel.Loading;
                return;
            }
            stop();
            model.status = FolderListModel.Ready;
            model.modelReset();
        }
    }

    Component.onCompleted: FolderListRegistry.add(model)
    Component.onDestruction: FolderListRegistry.remove(model)
}
