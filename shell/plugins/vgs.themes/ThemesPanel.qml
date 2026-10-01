import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "BrowserLogic.js" as BrowserLogic

// The themes panel: the current wallpaper with a step to the next or the
// previous one, then every theme package the runner lists, each with its
// palette and its state, and a click that applies one. It is built on
// summon and destroyed on hide, so everything it shows is read on open:
// the wallpaper from WallpaperState, which follows every change of the
// runner's state file, the list, and `last`, which the core keeps across
// instances, so a panel closed during an apply and reopened after it shows
// the result.
Item {
    id: root

    property var shell: null
    // The last list's packages, [] before it arrives or after it failed.
    property var packages: []
    // The last list's theme file: its state, its named package and whether
    // it is modified; null before the list arrives or after it failed.
    property var file: null
    // Why the last list failed, "" when it did not.
    property string listReason: ""
    // The catalog entries, [] before they arrive or after the read failed.
    property var catalogEntries: []
    // Why the last catalog read failed, "" when it did not.
    property string catalogReason: ""
    // `shell.theme.last` as last read: the apply running and the last
    // result. The capability's member is not a binding, so the panel reads
    // it again whenever an answer arrives.
    property var last: ({ applying: null, result: null, downloading: null })
    // Whether this panel instance has seen a running wallpaper download.
    property bool observedDownloadRunning: false
    // The package a click asked for and the refusal `apply` answered at
    // once, or null; shown on its row until the next click.
    property var refusal: null
    // The current wallpaper's file name, "" while no image is current.
    readonly property string wallpaperName: wallpaper.path === "" ? "" : wallpaper.path.slice(wallpaper.path.lastIndexOf("/") + 1)
    // The running wallpaper download's progress line, "" while none runs.
    readonly property string downloadProgress: BrowserLogic.progressText(last.downloading)
    // Whether a wallpaper step this instance asked for is still running.
    property bool stepping: false
    // Why the last wallpaper step failed, "" when it did not; shown until
    // the next click.
    property string stepProblem: ""
    // The catalog action this instance asked for, "" while none runs.
    property string catalogAction: ""
    // The catalog action kind: "install", "wallpapers" or "".
    property string catalogActionKind: ""
    // The last catalog action problem, or null. Shown on its catalog row.
    property var catalogProblem: null
    // A refused Add from URL TUI launch, "" when the last launch started.
    property string tuiProblem: ""
    readonly property bool canStep: wallpaper.path !== "" && !stepping
    property string currentKey: ""
    property Item initialFocus: themeList
    readonly property var installedKeys: packages.map(p => keyOf("installed", p))
    readonly property var catalogKeys: catalogEntries.map(e => keyOf("catalog", e))
    readonly property var rowKeys: installedKeys.concat(catalogKeys)
    readonly property var rowLabels: packages.map(p => p.name).concat(catalogEntries.map(e => e.name))

    // The panel takes no payload; what a summoner passes is ignored.
    function open(payloadJson) {
        refresh();
        Qt.callLater(() => {
            ensureCurrentKey();
        });
    }
    function close() {}

    // Read `last` and ask for the list. A list asked for while an apply
    // runs waits for it, so its answer is also when a running apply that
    // this instance did not start has finished.
    function refresh() {
        readLast();
        shell.theme.list(result => {
            root.listReason = result.reason === null ? "" : result.reason;
            root.packages = result.reason === null ? result.packages : [];
            root.file = result.file;
            root.ensureCurrentKey();
            root.readLast();
        });
        refreshCatalog();
    }

    function refreshCatalog() {
        shell.theme.catalog(result => {
            root.catalogReason = result.reason === null ? "" : result.reason;
            root.catalogEntries = result.reason === null ? result.entries : [];
            root.ensureCurrentKey();
            root.readLast();
        });
    }

    function readLast() {
        const wasDownloading = observedDownloadRunning;
        last = shell.theme.last;
        observedDownloadRunning = last.downloading !== null;
        if (wasDownloading && !observedDownloadRunning) refreshCatalog();
    }

    // Apply package `name`; answers the capability's reply.
    function apply(name) {
        const reply = shell.theme.apply(name, result => root.readLast());
        refusal = reply === "ok" ? null : { name: name, reply: reply };
        if (reply !== "ok") console.warn("themes panel: " + reply);
        readLast();
        return reply;
    }

    // Move to the applied package's `next` or `previous` wallpaper; answers
    // the capability's reply. `done` never runs before the reply.
    function step(direction) {
        stepProblem = "";
        const reply = shell.theme.background(direction, result => {
            root.stepping = false;
            if (result.state !== "ok") root.stepProblem = "The wallpaper step failed: " + result.reason;
        });
        if (reply !== "ok") {
            stepProblem = reply;
            console.warn("themes panel: " + reply);
            return reply;
        }
        stepping = true;
        return reply;
    }

    function addFromUrl() {
        const reply = shell.tui.open("core/theme-add");
        tuiProblem = reply === "ok" ? "" : reply;
        if (reply !== "ok") console.warn("themes panel: " + reply);
        return reply;
    }

    function catalogSwatch(entry) {
        const out = {};
        for (const key of Object.keys(entry.palette)) out[key] = Theme.toColor(entry.palette[key]);
        return out;
    }

    function wallpaperText(entry) {
        return entry.imagery === null ? "no wallpapers" : "wallpapers " + BrowserLogic.sizeText(entry.imagery.size);
    }

    function catalogActionLabel(entry) {
        if (!entry.installed) return "Install";
        if (entry.imagery !== null && !entry.imageryInstalled) return "Download wallpapers";
        return "";
    }

    function catalogLines(entry) {
        const lines = [];
        if (catalogProblem !== null && catalogProblem.name === entry.name) lines.push(catalogProblem.message);
        return lines;
    }

    function catalogBusyLabel(entry) {
        if (catalogAction === entry.name && catalogActionKind === "install") return "Installing";
        if ((catalogAction === entry.name && catalogActionKind === "wallpapers") || (last.downloading !== null && last.downloading.name === entry.name))
            return downloadProgress === "" ? "Downloading wallpapers" : downloadProgress;
        return "";
    }


    function displayedKey() {
        for (const p of packages)
            if (p.state === "ok" && p.name === Theme.name) return keyOf("installed", p);
        for (const e of catalogEntries)
            if (e.installed && e.name === Theme.name) return keyOf("catalog", e);
        return "";
    }

    function keyOf(section, row) {
        if (section === "installed") return "installed:" + row.source + "/" + row.name;
        if (section === "catalog") return "catalog:" + row.name;
        throw new Error("themes panel: section=" + section);
    }

    function keyIndex(key) {
        return rowKeys.indexOf(key);
    }

    function ensureCurrentKey() {
        if (rowKeys.length === 0) {
            currentKey = "";
            return;
        }
        if (keyIndex(currentKey) >= 0) return;
        const displayed = displayedKey();
        currentKey = displayed !== "" ? displayed : rowKeys[0];
    }

    function rowItemAt(index) {
        if (index < 0 || index >= rowKeys.length) return null;
        if (index < packages.length) return installedRows.itemAt(index);
        return catalogRows.itemAt(index - packages.length);
    }

    function activateRow(index) {
        const item = rowItemAt(index);
        if (item !== null) item.activate();
    }

    function secondaryRow(index) {
        const item = rowItemAt(index);
        return item !== null && item.requestAction();
    }

    function installCatalog(name) {
        catalogProblem = null;
        catalogAction = name;
        catalogActionKind = "install";
        const reply = shell.theme.install(name, result => {
            root.catalogAction = "";
            root.catalogActionKind = "";
            if (result.state !== "ok") root.catalogProblem = { name: name, message: "Install failed: " + result.reason };
            root.refresh();
        });
        if (reply !== "ok") {
            catalogAction = "";
            catalogActionKind = "";
            catalogProblem = { name: name, message: reply };
            console.warn("themes panel: " + reply);
        }
        return reply;
    }

    function downloadCatalogWallpapers(name) {
        catalogProblem = null;
        catalogAction = name;
        catalogActionKind = "wallpapers";
        const reply = shell.theme.wallpapers(name, result => {
            root.catalogAction = "";
            root.catalogActionKind = "";
            if (result.state !== "ok")
                root.catalogProblem = { name: name, message: "Wallpaper download failed: " + result.reason };
            root.refresh();
        });
        if (reply !== "ok") {
            catalogAction = "";
            catalogActionKind = "";
            catalogProblem = { name: name, message: reply };
            console.warn("themes panel: " + reply);
        }
        readLast();
        return reply;
    }

    WallpaperState { id: wallpaper }

    Timer {
        interval: BrowserLogic.PROGRESS_POLL_MS
        repeat: true
        running: root.catalogActionKind === "wallpapers" || root.last.downloading !== null
        onTriggered: root.readLast()
    }

    // The lines the row of package `name` shows for the last result: the
    // result's own refusal reason, then every target that did not land and
    // was not skipped, with its state and reason as the runner wrote them,
    // and one line per file of the package the apply dropped in favour of
    // the target's template, whatever the target's state. Only the states
    // that mean nothing went wrong are named here, so a state the runner
    // adds is shown without a change to the panel. A row with no `dropped`
    // dropped nothing.
    function resultLines(name) {
        const result = last.result;
        if (result === null || result.theme !== name) return [];
        const quiet = ["written", "unchanged", "skipped"];
        const lines = result.reason === null ? [] : [result.state + ": " + result.reason];
        for (const target of result.targets) {
            if (quiet.indexOf(target.state) === -1)
                lines.push(target.name + " " + target.state + (target.reason === null ? "" : ": " + target.reason));
            for (const file of target.dropped === undefined ? [] : target.dropped)
                lines.push(target.name + " dropped " + file);
        }
        return lines;
    }

    // Every line the row of package `name` shows: the last result's, then
    // the refusal a click on it was answered with.
    function linesFor(name) {
        const lines = resultLines(name);
        if (refusal !== null && refusal.name === name) lines.push(refusal.reply);
        return lines;
    }

    // The runner prints a new theme into the file before `done` runs, and
    // the shell's revision moves once it holds it: list again so the rows'
    // `current` and `modified` follow.
    Connections {
        target: Theme
        function onRevisionChanged() { root.refresh(); }
    }

    implicitWidth: Theme.size.panel.lg
    implicitHeight: layout.implicitHeight

    Surface {
        anchors.fill: parent
    }

    // One inset box: the title, the wallpaper, the installed packages and
    // the catalog in the scrolling body, and Add from URL in a footer that
    // stays in view while the body scrolls. The panel fits its content up
    // to `size.panel.maxHeight`.
    Pane {
        id: layout
        anchors.fill: parent
        container: "panel"
        fitToContent: true
        maximumHeight: Theme.size.panel.maxHeight

        header: [
            Label {
                role: "h3"
                text: "Themes"
            }
        ]

        ListCursor {
            id: themeCursor
            parent: layout.scrollArea.contentItem
        }

        // focus-indicator: the ListCursor plate marks the selected theme row.
        Item {
            id: themeList
            width: layout.contentWidth
            implicitHeight: themeBody.implicitHeight
            activeFocusOnTab: true
            focus: true
            Keys.onPressed: event => {
                if (event.modifiers === Qt.AltModifier && event.key === Qt.Key_D) {
                    event.accepted = root.secondaryRow(themeNav.currentIndex);
                    return;
                }
                event.accepted = themeNav.handle(event);
            }

            KeyNav {
                id: themeNav
                count: root.rowKeys.length
                currentIndex: root.keyIndex(root.currentKey)
                wrap: false
                viewHeight: layout.scrollArea.height
                rowHeight: Theme.listItem.height
                labelAt: index => root.rowLabels[index] || ""
                cursor: themeCursor
                flickable: layout.scrollArea
                itemAt: index => root.rowItemAt(index)
                onMoved: index => root.currentKey = root.rowKeys[index]
                onActivated: index => root.activateRow(index)
            }

            Column {
                id: themeBody
                width: parent.width
                spacing: layout.bodySpacing

                Section {
            id: wallpaperSection
            title: "Wallpaper"
            description: "The applied theme's background image; the buttons step through its package's images"

            Item {
                width: wallpaperSection.width
                implicitHeight: Math.max(wallpaperLabel.lineBox, nextWallpaper.implicitHeight)

                Label {
                    id: wallpaperLabel
                    role: "item"
                    anchors.left: parent.left
                    anchors.right: previousWallpaper.left
                    anchors.rightMargin: Theme.stack.inline
                    y: topForCapCenter(parent.height)
                    elide: Text.ElideMiddle
                    text: root.wallpaperName === "" ? "None" : root.wallpaperName
                }
                IconButton {
                    id: previousWallpaper
                    anchors.right: nextWallpaper.left
                    anchors.rightMargin: Theme.stack.inline
                    anchors.verticalCenter: parent.verticalCenter
                    size: "sm"
                    iconName: "chevron-left"
                    label: "Previous wallpaper"
                    enabled: root.canStep
                    onClicked: root.step("previous")
                }
                IconButton {
                    id: nextWallpaper
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    size: "sm"
                    iconName: "chevron-right"
                    label: "Next wallpaper"
                    enabled: root.canStep
                    onClicked: root.step("next")
                }
            }

            Label {
                role: "hint"
                width: wallpaperSection.width
                visible: text !== ""
                text: root.stepProblem
                color: Theme.color.danger
                wrapMode: Text.Wrap
            }
        }

        Section {
            id: installedSection
            title: "Installed"
            description: "Every theme package; a click applies one to the shell and every application target"

            Label {
                role: "hint"
                width: installedSection.width
                visible: text !== ""
                text: root.listReason === "" ? "" : "The theme list failed: " + root.listReason
                color: Theme.color.danger
                wrapMode: Text.Wrap
            }

            // A list asked for during an apply arrives after it, so a
            // panel opened while one runs names it here until then.
            Row {
                spacing: Theme.control.gap
                visible: root.last.applying !== null
                Spinner { anchors.verticalCenter: parent.verticalCenter }
                Label {
                    role: "item"
                    text: "Applying " + root.last.applying
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Repeater {
                id: installedRows
                model: ScriptModel {
                    values: root.packages.map(p => Object.assign({ key: p.source + "/" + p.name }, p))
                    objectProp: "key"
                }

                ThemeRow {
                    required property var modelData
                    // The section, not `parent`, which is null while the
                    // repeater tears the row down.
                    width: installedSection.width
                    rowKey: root.keyOf("installed", modelData)
                    currentKey: root.currentKey
                    cursor: themeCursor
                    listActiveFocus: themeList.activeFocus
                    name: modelData.name
                    source: modelData.source
                    packageState: modelData.state
                    reason: modelData.reason === null ? "" : modelData.reason
                    swatch: modelData.state === "ok" ? root.shell.theme.swatch(modelData.name) : null
                    displayed: modelData.state === "ok" && modelData.name === Theme.name
                    modified: modelData.state === "ok" && modelData.current && root.file !== null && root.file.modified === true
                    applying: modelData.state === "ok" && root.last.applying === modelData.name
                    applicable: modelData.state === "ok" && root.last.applying === null
                    lines: modelData.state === "shadowed" ? [] : root.linesFor(modelData.name)
                    onPointed: key => root.currentKey = key
                    onActivated: root.apply(modelData.name)
                }
            }
        }

        Section {
            id: catalogSection
            title: "Catalog"
            description: "Themes VGS ships in its catalog; install a definition first, then download its wallpapers"

            Label {
                role: "hint"
                width: catalogSection.width
                visible: text !== ""
                text: root.catalogReason === "" ? "" : "The theme catalog failed: " + root.catalogReason
                color: Theme.color.danger
                wrapMode: Text.Wrap
            }

            Repeater {
                id: catalogRows
                model: ScriptModel {
                    values: root.catalogEntries.map(e => Object.assign({ key: e.name }, e))
                    objectProp: "key"
                }

                ThemeRow {
                    required property var modelData
                    width: catalogSection.width
                    rowKey: root.keyOf("catalog", modelData)
                    currentKey: root.currentKey
                    cursor: themeCursor
                    listActiveFocus: themeList.activeFocus
                    name: modelData.name
                    source: modelData.mode + ", " + root.wallpaperText(modelData)
                    packageState: "catalog"
                    swatch: root.catalogSwatch(modelData)
                    installed: modelData.installed
                    displayed: modelData.installed && modelData.name === Theme.name
                    definitionUpdate: modelData.definitionUpdate
                    imageryUpdate: modelData.imageryUpdate
                    applicable: modelData.installed && root.last.applying === null
                    applying: root.last.applying === modelData.name
                    actionLabel: root.catalogActionLabel(modelData)
                    actionIcon: modelData.installed ? "cloud-download" : "package-plus"
                    actionEnabled: root.catalogAction === "" && root.last.applying === null
                    lines: root.catalogLines(modelData)
                    busyText: root.catalogBusyLabel(modelData)
                    onPointed: key => root.currentKey = key
                    onActivated: root.apply(modelData.name)
                    onActionRequested: modelData.installed ? root.downloadCatalogWallpapers(modelData.name) : root.installCatalog(modelData.name)
                }
            }
        }

            }
        }

        footer: [
            Column {
                width: layout.contentWidth
                spacing: Theme.stack.row

                Button {
                    width: parent.width
                    variant: "secondary"
                    text: "Add from URL"
                    iconName: "package-plus"
                    onClicked: root.addFromUrl()
                }
                Label {
                    role: "hint"
                    width: parent.width
                    visible: text !== ""
                    text: root.tuiProblem
                    color: Theme.color.danger
                    wrapMode: Text.Wrap
                }
            }
        ]
    }
}
