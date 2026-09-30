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
    // The folder model falls back to the working directory for a folder
    // that does not exist (runtime-qml.md), so the folder it lists names
    // whether the folder the picker shows exists.
    readonly property string actualFolder: clean(String(folders.folder || ""))
    readonly property bool folderFound: actualFolder === currentFolder
    // Whether the typed or chosen path exists, read while the picker's
    // folder is that path and kept while the picker browses elsewhere.
    property bool displayFound: true
    readonly property bool valid: absolute && (displayPath === "" || displayFound)
    onFolderFoundChanged: syncDisplayFound()
    onActualFolderChanged: syncDisplayFound()
    signal changed(string path)
    signal edited(string path, bool valid)
    signal picked(string path)

    onPathChanged: {
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
