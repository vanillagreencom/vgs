import QtQuick
import QtCore
import Qt.labs.folderlistmodel
import qs.Commons
import qs.Ui

// An absolute path field with a directory-only picker. Browse opens a
// keyboard-navigable list with Home and parent shortcuts.
Item {
    id: root

    property string path: ""
    property string displayPath: path
    property string currentFolder: displayPath !== "" && displayPath.charAt(0) === "/" ? displayPath : homePath()
    property bool error: false
    property string errorMessage: ""
    readonly property bool absolute: isAbsolute(displayPath)
    // runtime-qml-folders.md defines the folder model's answer order: `status`
    // becomes Null synchronously for a missing folder, while `folder` can
    // keep the last folder whose listing arrived.
    readonly property string actualFolder: clean(String(folders.folder || ""))
    readonly property int folderStatus: folders.status
    readonly property bool folderSettled: folderStatus !== FolderListModel.Loading
    readonly property bool folderFound: actualFolder === currentFolder && folderSettled && folderStatus !== FolderListModel.Null
    // Whether the typed or chosen path exists, read while the picker's
    // folder is that path and kept while the picker browses elsewhere.
    property bool displayFound: true
    readonly property bool valid: absolute && (displayPath === "" || displayFound)
    property string typedPath: ""
    onFolderFoundChanged: syncDisplayFound()
    onActualFolderChanged: syncDisplayFound()
    onDisplayFoundChanged: if (typedPath !== "" && displayPath === typedPath) edited(displayPath, absolute && (displayPath === "" || displayFound))
    // `changed` reports each user or picker change. `edited` reports a
    // user text edit at once, and again when the folder check for that
    // same shown text settles to a different validity.
    signal changed(string path)
    signal edited(string path, bool valid)
    signal picked(string path)

    onPathChanged: {
        if (path !== typedPath) typedPath = "";
        displayPath = path;
        if (path !== "" && path.charAt(0) === "/") currentFolder = clean(path);
    }

    implicitWidth: field.implicitWidth
    implicitHeight: field.implicitHeight

    function syncDisplayFound() {
        if (displayPath !== "" && isAbsolute(displayPath) && clean(displayPath) === currentFolder) displayFound = folderFound;
    }
    function homePath() { return StandardPaths.writableLocation(StandardPaths.HomeLocation); }
    function isAbsolute(value) { return value === "" || value.charAt(0) === "/"; }
    function clean(value) {
        const text = String(value || "");
        return text.replace(/^file:\/\//, "").replace(/\/+$/, "") || "/";
    }
    function parentPath(value) {
        const trimmed = clean(value);
        const at = trimmed.lastIndexOf("/");
        return at <= 0 ? "/" : trimmed.slice(0, at);
    }
    function choose(value) {
        const chosen = clean(value);
        if (!folderFound && chosen === currentFolder) {
            errorMessage = "Folder not found.";
            return;
        }
        displayPath = chosen;
        currentFolder = chosen;
        displayFound = true;
        typedPath = "";
        errorMessage = "";
        picked(chosen);
        changed(chosen);
        picker.close();
    }
    function openFolder(value) { currentFolder = clean(value); errorMessage = ""; }
    function entryPath(index) {
        if (index < 0 || index >= folders.count) return "";
        const fromRole = folders.get(index, "filePath");
        return fromRole === undefined ? "" : String(fromRole);
    }

    TextField {
        id: field
        anchors.fill: parent
        text: root.displayPath
        placeholderText: "Working directory, blank for home"
        error: root.error || !root.valid
        onTextEdited: {
            root.displayPath = text;
            if (text.charAt(0) === "/") root.currentFolder = root.clean(text);
            root.errorMessage = "";
            root.typedPath = text !== "" && text.charAt(0) === "/" ? text : "";
            root.edited(text, root.valid);
            root.changed(text);
        }
        actions: [ Button { text: "Browse"; size: "sm"; variant: "secondary"; onClicked: picker.toggle() } ]
    }

    Popover {
        id: picker
        width: Theme.size.panel.sm
        onOpenedChanged: if (opened) Qt.callLater(() => list.forceActiveFocus())

        Column {
            width: parent.width
            spacing: Theme.space.xs
            Row {
                width: parent.width
                spacing: Theme.space.xs
                Button { text: "Home"; size: "sm"; variant: "secondary"; onClicked: root.openFolder(root.homePath()) }
                Button { text: "Parent"; size: "sm"; variant: "secondary"; onClicked: root.openFolder(root.parentPath(root.currentFolder)) }
                Button { text: "Choose"; size: "sm"; enabled: root.folderFound; onClicked: root.choose(root.currentFolder) }
            }
            Label { width: parent.width; role: "hint"; text: root.currentFolder; elide: Text.ElideMiddle }
            Label { width: parent.width; role: "hint"; color: Theme.color.danger; text: root.errorMessage !== "" ? root.errorMessage : root.folderFound ? "" : "Folder not found."; visible: text !== ""; wrapMode: Text.Wrap }
            ListView {
                id: list
                width: parent.width
                height: Math.min(contentHeight, Theme.size.panel.sm)
                model: FolderListModel {
                    id: folders
                    folder: "file://" + root.currentFolder
                    showDirs: true
                    showFiles: false
                    showDotAndDotDot: false
                    showHidden: false
                }
                clip: true
                acceptedButtons: Qt.NoButton
                focus: true
                delegate: ListItem {
                    required property int index
                    property string filePath: root.entryPath(index)
                    property string fileName: filePath === "" ? "" : filePath.slice(filePath.lastIndexOf("/") + 1)
                    width: ListView.view.width
                    text: fileName
                    iconName: "folder"
                    onClicked: root.openFolder(filePath)
                }
                Keys.onReturnPressed: {
                    const item = itemAtIndex(currentIndex);
                    if (item !== null) root.openFolder(item.filePath);
                    else root.choose(root.currentFolder);
                }
                Keys.onEnterPressed: {
                    const item = itemAtIndex(currentIndex);
                    if (item !== null) root.openFolder(item.filePath);
                    else root.choose(root.currentFolder);
                }
                Keys.onEscapePressed: picker.close()
            }
        }
    }
}
