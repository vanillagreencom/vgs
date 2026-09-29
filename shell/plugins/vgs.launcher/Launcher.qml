import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Appearance.js" as Appearance
import "MenuModel.js" as MenuModel

// The launcher: the Spotlight glass card the overlay host draws on the
// screen it was summoned on. It opens as a bare search field; typing
// searches every menu row and application, `f:` and `F:` search files and
// folders, and Ctrl+B or the menu button shows the category tree. A payload
// with `mode` `select` or `input` turns it into a picker that answers
// through two files (README). Closed, it holds no surface: the host builds
// it on summon and destroys it on hide. Every value it draws with is `look`,
// its own table resolved against the theme's mode and accent alone.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)

    // ------------------------------------------------------------ lifecycle

    property bool opened: false
    // "menu", or a picker: "select" or "input".
    property string mode: "menu"
    readonly property bool requestMode: mode === "select" || mode === "input"
    // { selectionFile, doneFile } while a picker waits for its answer.
    property var request: null
    property string prompt: ""
    property var options: []
    property int requestWidth: 0
    property int requestMaxHeight: 0

    // The host calls open() on summon and again on a summon while open. A
    // payload the judge refuses throws, and the host refuses the summon.
    function open(payloadJson) {
        if (look === null) throw new Error("launcher: refused: appearance");
        const judged = MenuModel.parsePayload(payloadJson, Quickshell.env("XDG_RUNTIME_DIR") || "");
        if (!judged.ok) throw new Error("launcher: refused: " + judged.error);
        const payload = judged.payload;
        // A picker still waiting is answered `cancel` by the next summon.
        finishRequest(null);
        if (payload.mode !== "menu") openRequest(payload);
        else if (menusReady) openRoute(payload.menu, payload.query);
        // A route can name a row of either file, so it waits for both.
        else pendingRoute = payload;
    }

    property var pendingRoute: null
    onMenusReadyChanged: {
        if (!menusReady || pendingRoute === null) return;
        const payload = pendingRoute;
        pendingRoute = null;
        openRoute(payload.menu, payload.query);
    }

    // The host calls close() before it destroys the surface.
    function close() {
        finishRequest(null);
        fileSearch.clear();
        opened = false;
    }

    Component.onDestruction: finishRequest(null)

    // Close from inside: the card fades out, then the host takes the
    // surface down.
    function dismiss() {
        if (!opened) return;
        opened = false;
        cardEntrance.stop();
        card.closing = true;
        cardExit.restart();
    }

    function hideSurface() {
        if (root.shell === null) return;
        const reply = root.shell.surfaces.hide("overlay");
        if (reply !== "ok") console.error("launcher: hide refused: " + reply);
    }

    function cancel() {
        finishRequest(null);
        dismiss();
    }

    // ------------------------------------------------------------ the menu

    readonly property string shippedPath: decodeURIComponent(String(Qt.resolvedUrl("menu.json")).replace(/^file:\/\//, ""))
    readonly property string userDir: Paths.configDir + "/launcher"
    readonly property string userPath: userDir + "/menu.json"
    property var shippedEntries: []
    property var userEntries: []
    // A menu file the judge refused, by source, shown as a notice row.
    property var menuErrors: ({})
    property var items: ({})
    property var itemOrder: []
    property bool rowsLoaded: false
    // Each file has been read or found absent at least once.
    property bool shippedSettled: false
    property bool userSettled: false
    readonly property bool menusReady: shippedSettled && userSettled
    property var providersLoaded: ({})
    // Commands a row's `requires` names that are not on PATH.
    property var missing: []
    // Every listed TUI, which the menu's `tui` rows resolve against. The
    // core assigns `shell` after creation, so the rows resolve again then,
    // and whenever a plugin's enable changes the list.
    readonly property var tuiEntries: shell === null ? [] : shell.tui.entries
    onTuiEntriesChanged: {
        items = MenuModel.resolveTuiRows(items, itemOrder, tuiEntries);
        if (opened) rebuildDisplay();
    }

    function readMenu(source, path, text) {
        const parsed = MenuModel.parseMenu(text);
        const errors = Object.assign({}, menuErrors);
        delete errors[source];
        if (parsed.ok) {
            if (source === "shipped") shippedEntries = parsed.entries;
            else userEntries = parsed.entries;
        } else {
            console.error("launcher: menu refused: file=" + path + " " + parsed.error);
            errors[source] = parsed.error;
            if (source === "shipped") shippedEntries = [];
            else userEntries = [];
        }
        menuErrors = errors;
        rebuildItems();
    }

    function rebuildItems() {
        let merged = MenuModel.mergeMenuSources(shippedEntries, userEntries);
        if (!merged.ok) {
            console.error("launcher: menu refused: file=" + userPath + " " + merged.error);
            const errors = Object.assign({}, menuErrors);
            errors.user = merged.error;
            menuErrors = errors;
            merged = MenuModel.mergeMenuSources(shippedEntries, []);
        }
        items = MenuModel.resolveTuiRows(merged.items, merged.itemOrder, tuiEntries);
        itemOrder = merged.itemOrder;
        providersLoaded = ({});
        rowsLoaded = true;
        checkRequires();
        if (opened) {
            rebuildDisplay();
            loadProvider(activeMenu);
            if (filterText.trim()) loadProvidersForSearch();
        }
    }

    FileView {
        id: shippedFile
        path: root.shippedPath
        blockLoading: true
        printErrors: false
        onLoaded: {
            root.readMenu("shipped", path, text());
            root.shippedSettled = true;
        }
        onLoadFailed: error => {
            root.readMenu("shipped", path, "");
            root.shippedSettled = true;
        }
    }

    // A watcher adds only a directory that exists when it is built
    // (docs/architecture/runtime-qml.md), so the user menu's directory is
    // made before its watch starts: a menu first created there while the
    // launcher is open is then read. A directory that could not be made is
    // logged and the watch starts anyway, reading the menu as absent.
    Process {
        id: userDirProc
        property var completion: null
        property bool settled: false
        command: ["mkdir", "-p", "--", root.userDir]
        running: true
        stderr: StdioCollector { id: userDirErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (completion === null || completion.code !== 0 || completion.status !== 0)
                console.error("launcher: menu directory failed: dir=" + root.userDir + " " + JSON.stringify(completion) + "\n" + userDirErr.text.trim());
            settled = true;
        }
    }

    // Read again on every change, a change that lands during a read
    // included. The first read ends after open(), so a route waits for
    // userSettled in pendingRoute.
    LazyLoader {
        active: userDirProc.settled
        WatchedFile {
            path: root.userPath
            onChanged: read()
            onLoaded: content => {
                root.readMenu("user", path, content);
                root.userSettled = true;
            }
            onLoadFailed: error => {
                if (error === FileViewError.FileNotFound) {
                    const errors = Object.assign({}, root.menuErrors);
                    delete errors.user;
                    root.menuErrors = errors;
                    root.userEntries = [];
                    root.rebuildItems();
                } else {
                    root.readMenu("user", path, "");
                }
                root.userSettled = true;
            }
        }
    }

    // Every command any row requires, checked in one process per menu.
    function checkRequires() {
        const wanted = [];
        for (const id of itemOrder)
            for (const command of items[id].requires)
                if (wanted.indexOf(command) === -1) wanted.push(command);
        if (wanted.length === 0) {
            missing = [];
            return;
        }
        if (requiresProc.running) {
            requiresProc.again = true;
            return;
        }
        requiresProc.completion = null;
        requiresProc.command = ["sh", "-c", "for c do command -v -- \"$c\" >/dev/null 2>&1 || printf '%s\\n' \"$c\"; done", "sh"].concat(wanted);
        requiresProc.running = true;
    }

    Process {
        id: requiresProc
        property var completion: null
        property bool again: false
        stdout: StdioCollector { id: requiresOut }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (completion === null || completion.code !== 0 || completion.status !== 0)
                console.error("launcher: requires check failed: " + JSON.stringify(completion));
            else root.missing = requiresOut.text.split("\n").filter(line => line.length > 0);
            if (again) {
                again = false;
                root.checkRequires();
            }
            if (root.opened) root.rebuildDisplay();
        }
    }

    // ------------------------------------------------------------ providers

    function loadProvider(id) {
        const entry = items[id];
        if (!entry || !entry.provider || providersLoaded[id]) return;
        const loaded = Object.assign({}, providersLoaded);
        loaded[id] = true;
        providersLoaded = loaded;
        if (entry.provider === "apps") mergeAppRows(id);
        else if (entry.provider === "themes") loadThemes(id);
    }

    function loadProvidersForSearch() {
        const active = items[activeMenu] ? activeMenu : "root";
        for (const id of itemOrder) {
            if (!items[id].provider || providersLoaded[id]) continue;
            if (active !== "root" && id !== active && !MenuModel.isDescendantOf(items, id, active)) continue;
            loadProvider(id);
        }
    }

    function swapRows(menuId, rows) {
        const merged = MenuModel.swapProviderRows(items, itemOrder, menuId, rows);
        items = merged.items;
        itemOrder = merged.itemOrder;
        if (opened) rebuildDisplay();
    }

    function mergeAppRows(menuId) {
        const rows = DesktopEntries.applications.values.map(entry => MenuModel.appRow(menuId, {
            id: entry.id, name: entry.name, genericName: entry.genericName, comment: entry.comment, keywords: entry.keywords, icon: entry.icon
        }));
        swapRows(menuId, rows);
    }

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            for (const id of root.itemOrder)
                if (root.items[id].provider === "apps" && root.providersLoaded[id]) root.mergeAppRows(id);
        }
    }

    // Theme packages come from the theme capability; a list that fails
    // shows why in place of the rows.
    function loadThemes(menuId) {
        if (shell === null || shell.theme === undefined) return;
        shell.theme.list(listing => {
            if (listing.packages === null) {
                root.swapRows(menuId, [MenuModel.themeRow(menuId, { name: "unlisted", state: "refused", reason: listing.reason })]);
                return;
            }
            root.swapRows(menuId, listing.packages.map(pkg => MenuModel.themeRow(menuId, pkg)));
        });
    }

    // ------------------------------------------------------------ navigation

    property string activeMenu: "root"
    property string filterText: ""
    property int selectedIndex: 0
    property bool cursorActive: false
    property var navStack: []
    // The root opens as a bare search field; its categories show while
    // this is on (Ctrl+B or the menu button).
    property bool showCategories: false
    readonly property bool spotlightRoot: !requestMode && activeMenu === "root"
    readonly property bool searching: filterText.length > 0
    readonly property var fileQuery: requestMode ? MenuModel.fileMode("") : MenuModel.fileMode(filterText)
    readonly property string fileMode: fileQuery.mode
    // While set, the list shows the applications that open this file.
    property var openWithTarget: null
    property var openWithApps: []
    // One line the launcher owes the user now, such as an action it cannot
    // take; the next edit of the search clears it.
    property string notice: ""

    function openRoute(route, query) {
        const id = MenuModel.resolveRoute(items, itemOrder, route);
        const entry = items[id];
        // A route naming an action runs it; one naming a link follows it.
        if (entry && entry.kind === "action") {
            runArgv(entry.run);
            if (opened) dismiss();
            else Qt.callLater(hideSurface);
            return;
        }
        const target = entry && entry.kind === "link" ? entry.target : id;
        mode = "menu";
        request = null;
        resetState();
        activeMenu = items[target] ? target : "root";
        navStack = [];
        cursorActive = true;
        show();
        loadProvider(activeMenu);
        if (query) setFilter(query);
    }

    function openRequest(payload) {
        resetState();
        mode = payload.mode;
        prompt = payload.prompt;
        options = payload.options;
        request = { selectionFile: payload.selectionFile, doneFile: payload.doneFile };
        requestWidth = payload.width;
        requestMaxHeight = payload.maxHeight;
        activeMenu = "root";
        navStack = [];
        cursorActive = mode !== "input";
        show();
    }

    // Every open starts clean: no category tree, file search, open-with
    // list, flyout or notice from an earlier one.
    function resetState() {
        showCategories = false;
        openWithTarget = null;
        openWithApps = [];
        notice = "";
        filterText = "";
        selectedIndex = 0;
        fileSearch.clear();
        fileFlyout.dismiss();
        disarmPointer();
    }

    function show() {
        navReset = true;
        navDirection = 0;
        const reopened = card.closing;
        opened = true;
        if (reopened) {
            cardExit.stop();
            card.closing = false;
        }
        if (!card.entered || reopened) card.enter();
        rebuildDisplay();
        Qt.callLater(() => keyCatcher.forceActiveFocus());
    }

    function setFilter(next) {
        freezeCardTop();
        filterText = next;
        selectedIndex = 0;
        cursorActive = mode !== "input";
        notice = "";
        disarmPointer();
        openWithTarget = null;
        if (fileMode) fileSearch.request(fileMode, fileQuery.query);
        else if (fileSearch.mode) fileSearch.clear();
        if (!requestMode && !fileMode && filterText.trim()) loadProvidersForSearch();
        rebuildDisplay();
    }

    function setActiveMenu(id, forward, fromPointer) {
        navReset = true;
        navDirection = forward ? 1 : -1;
        freezeCardTop();
        if (!items[id]) id = "root";
        if (forward && id !== activeMenu) navStack = navStack.concat([activeMenu]);
        activeMenu = id;
        filterText = "";
        selectedIndex = 0;
        cursorActive = true;
        notice = "";
        if (fromPointer) pointerArmed = true;
        else disarmPointer();
        // A provider's list may have changed since it last opened.
        if (items[id] && items[id].provider) {
            const loaded = Object.assign({}, providersLoaded);
            delete loaded[id];
            providersLoaded = loaded;
        }
        rebuildDisplay();
        loadProvider(id);
    }

    function goBack() {
        if (activeMenu === "root") return false;
        if (navStack.length > 0) {
            const previous = navStack[navStack.length - 1];
            navStack = navStack.slice(0, -1);
            setActiveMenu(previous, false);
            return true;
        }
        const active = items[activeMenu];
        setActiveMenu(active && active.parent ? active.parent : "root", false);
        return true;
    }

    function toggleCategories() {
        showCategories = !showCategories;
        navDirection = 0;
        selectedIndex = 0;
        disarmPointer();
        rebuildDisplay();
    }

    // ------------------------------------------------------------ actions

    function runArgv(argv) {
        const reply = shell === null ? "refused: shell=none" : shell.run.detached(argv);
        if (reply !== "ok") console.error("launcher: run " + JSON.stringify(argv) + " " + reply);
        return reply;
    }

    // A listed TUI by key. The launcher closes on the core's shown answer;
    // any other answer is logged and stays in the list as a notice.
    function openTui(key) {
        const reply = shell === null ? "refused: shell=none" : shell.tui.open(key);
        if (reply === "ok") {
            dismiss();
            return;
        }
        console.error("launcher: tui " + key + " " + reply);
        notice = reply;
        rebuildDisplay();
    }

    function launchApp(appId) {
        const entry = DesktopEntries.byId(appId);
        if (entry === null) {
            notice = "The application is gone: " + appId;
            rebuildDisplay();
            return;
        }
        // `command` is a QML list; the run capability takes an array.
        const argv = Array.from(entry.command);
        const command = entry.runInTerminal ? ["xdg-terminal-exec"].concat(argv) : argv;
        if (runArgv(command) === "ok") dismiss();
    }

    function activateIndex(index, fromPointer) {
        if (index < 0 || index >= displayModel.count) {
            if (mode === "input") finishAndDismiss(filterText);
            return;
        }
        const row = displayModel.get(index);
        switch (row.kind) {
        case "option":
            finishAndDismiss(MenuModel.selectionOf(row));
            return;
        case "file":
        case "folder":
            if (runArgv(["gio", "open", row.path]) === "ok") dismiss();
            return;
        case "openwith":
            runOpenWith(row.target, row.path);
            return;
        case "menu":
        case "link":
            setActiveMenu(row.target || row.itemId, true, fromPointer);
            return;
        case "app":
            launchApp(items[row.itemId].appId);
            return;
        case "action":
            if (runArgv(items[row.itemId].run) === "ok") dismiss();
            return;
        case "tui":
            openTui(items[row.itemId].tuiKey);
            return;
        case "theme":
            applyTheme(items[row.itemId].theme);
            return;
        case "unavailable":
        case "notice":
            caret.nudge();
            return;
        }
        console.error("launcher: row kind " + row.kind + " has no action");
    }

    function applyTheme(name) {
        if (shell === null || shell.theme === undefined) return;
        const reply = shell.theme.apply(name, result => {
            if (!MenuModel.applySucceeded(result)) console.error("launcher: theme " + name + " " + JSON.stringify(result));
        });
        if (reply === "ok") dismiss();
        else {
            notice = reply;
            rebuildDisplay();
        }
    }

    // The Remove row's picker opens with no arguments, so nothing can hand it
    // the package of one application. Delete points at that row instead of
    // removing anything.
    function requestRemove() {
        if (!cursorActive || selectedIndex < 0 || selectedIndex >= displayModel.count) return;
        if (displayModel.get(selectedIndex).kind !== "app") return;
        notice = "Removing one application is not available here: use Remove to pick packages";
        rebuildDisplay();
    }

    // ------------------------------------------------------------ pickers

    function finishAndDismiss(selection) {
        finishRequest(selection);
        dismiss();
    }

    // Answer a waiting picker once: its selection, then `ok` in the done
    // file, or `cancel` alone. A selection write that fails says `error` in
    // the done file, and is logged. The selection is written here, while
    // the launcher is alive to pick; the done file is written by a detached
    // process through the run capability, since a cancel also comes from
    // close() as the host destroys the launcher, and it is renamed into
    // place, so a waiter never reads half of it.
    function finishRequest(selection) {
        if (request === null) return;
        const answer = request;
        request = null;
        let status = selection === null ? "cancel" : "ok";
        if (selection !== null) {
            selectionWriter.failed = false;
            selectionWriter.path = answer.selectionFile;
            selectionWriter.setText(selection + "\n");
            if (selectionWriter.failed) status = "error";
        }
        runArgv(["sh", "-c", "printf '%s\\n' \"$1\" >\"$2.tmp\" && mv -f -- \"$2.tmp\" \"$2\"", "sh", status, answer.doneFile]);
    }

    FileView {
        id: selectionWriter
        property bool failed: false
        preload: false
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onSaveFailed: error => {
            failed = true;
            console.error("launcher: selection write failed: file=" + path + " error=" + error);
        }
    }


    // ------------------------------------------------------------ files

    FileSearch {
        id: fileSearch
        look: root.look
        onResultsChanged: if (root.opened && root.fileMode && !root.openWithTarget) root.rebuildDisplay()
        onErrorChanged: if (root.opened && root.fileMode) root.rebuildDisplay()
    }

    function row(itemId, kind, icon, appIcon, label, target, detail, path) {
        return { itemId: itemId, kind: kind, icon: icon, appIcon: appIcon, label: label, target: target, detail: detail, path: path, childCount: 0, score: 0, section: "" };
    }

    function fileRows() {
        const rows = [];
        if (openWithTarget) {
            for (const app of openWithApps)
                rows.push(row("with:" + app.desktopFile, "openwith", "", app.icon, app.name, app.desktopFile, app.isDefault ? "Default" : "", openWithTarget.path));
            rows.push(row("with:reveal", "openwith", "folder-open", "", "Show in folder", "reveal", "", openWithTarget.path));
            rows.push(row("with:copy", "openwith", "copy", "", "Copy path", "copy", "", openWithTarget.path));
            return rows;
        }
        if (fileSearch.error) rows.push(row("notice.files", "notice", "info", "", "File search unavailable", "", fileSearch.error, ""));
        for (const hit of fileSearch.results)
            rows.push(row("file:" + hit.path, fileMode === "d" ? "folder" : "file", "", fileSearch.iconFor(hit.mime), hit.name, "", hit.dir, hit.path));
        return rows;
    }

    function showOpenWith(path, name) {
        fileFlyout.dismiss();
        openWithTarget = { path: path, name: name };
        openWithApps = [];
        navReset = true;
        navDirection = 1;
        fileSearch.loadApps(path, apps => {
            if (!root.openWithTarget || root.openWithTarget.path !== path) return;
            root.openWithApps = apps;
            root.navReset = true;
            root.rebuildDisplay();
        });
        selectedIndex = 0;
        rebuildDisplay();
    }

    function leaveOpenWith() {
        openWithTarget = null;
        navReset = true;
        navDirection = -1;
        selectedIndex = 0;
        rebuildDisplay();
    }

    function runOpenWith(action, path) {
        let argv;
        if (action === "reveal") argv = ["gio", "open", path.substring(0, path.lastIndexOf("/")) || "/"];
        else if (action === "copy") argv = ["wl-copy", "--", path];
        else argv = ["gio", "launch", action, path];
        if (runArgv(argv) === "ok") dismiss();
    }

    // The right-click flyout for a file row, at a point in the card's parent.
    function openFileFlyout(path, name, px, py) {
        if (openWithTarget) leaveOpenWith();
        fileFlyout.targetPath = path;
        fileFlyout.items = [];
        fileFlyout.openAt(px, py);
        fileSearch.loadApps(path, apps => {
            if (fileFlyout.targetPath !== path) return;
            const entries = apps.map(app => ({ id: "app:" + app.desktopFile, label: app.name, icon: app.icon, detail: app.isDefault ? "Default" : "" }));
            entries.push({ separator: true, id: "sep" });
            entries.push({ id: "reveal", label: "Show in folder", glyph: "folder-open" });
            entries.push({ id: "copy", label: "Copy path", glyph: "copy" });
            fileFlyout.items = entries;
        });
    }

    // ------------------------------------------------------------ rows

    ListModel { id: displayModel }

    // Rows new since the last rebuild fade in, staggered; rows that stay
    // appear at once, so typing never flickers the list. A menu change
    // (`navReset`) treats every row as new and slides it in from the side it
    // came from (`navDirection`: 1 into a submenu, -1 back out).
    property var freshIds: ({})
    property int navDirection: 0
    property bool navReset: false
    property int layoutSerial: 0

    function displayedIds() {
        const ids = {};
        if (!navReset) for (let i = 0; i < displayModel.count; i++) ids[displayModel.get(i).itemId] = true;
        return ids;
    }

    function markFresh(previous) {
        const fresh = {};
        for (let i = 0; i < displayModel.count; i++) {
            const id = displayModel.get(i).itemId;
            if (!previous[id]) fresh[id] = true;
        }
        freshIds = fresh;
        navReset = false;
        freshReset.restart();
    }

    Timer {
        id: freshReset
        interval: root.look.motion.freshReset
        onTriggered: {
            root.freshIds = ({});
            root.navDirection = 0;
        }
    }

    function noticeRows() {
        const rows = [];
        if (notice) rows.push(row("notice.now", "notice", "info", "", notice, "", "", ""));
        if (requestMode || fileMode || !(searching || showCategories || activeMenu !== "root")) return rows;
        for (const source of Object.keys(menuErrors))
            rows.push(row("notice.menu." + source, "notice", "info", "", source === "user" ? "Your menu file was refused" : "The shipped menu was refused", "", menuErrors[source], ""));
        return rows;
    }

    function rebuildDisplay() {
        cursorPlate.snap = true;
        Qt.callLater(() => { cursorPlate.snap = false; });
        const previous = displayedIds();
        let rows = [];
        const active = items[activeMenu] ? activeMenu : "root";
        const query = filterText.trim();
        if (requestMode) rows = mode === "input" ? [] : MenuModel.optionRows(options, filterText);
        else if (!rowsLoaded) rows = [];
        else if (fileMode) rows = fileRows();
        else if (query) rows = MenuModel.searchRows(items, itemOrder, active, query, missing);
        else if (active !== "root" || showCategories) rows = MenuModel.menuRows(items, itemOrder, active, missing);
        rows = noticeRows().concat(rows);
        displayModel.clear();
        for (const r of rows) displayModel.append(r);
        layoutSerial += 1;
        markFresh(previous);
        if (displayModel.count === 0) selectedIndex = 0;
        else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1;
        else if (selectedIndex < 0) selectedIndex = 0;
        Qt.callLater(revealCursor);
    }

    // Rows fold on whole rows: the cursor row stays flush with the edge it
    // moves toward.
    function revealCursor() {
        if (displayModel.count === 0) return;
        resultList.positionViewAtIndex(selectedIndex, ListView.Contain);
        const item = resultList.itemAtIndex(selectedIndex);
        if (!item) return;
        if (selectedIndex < displayModel.count - 1) {
            const maxY = Math.max(resultList.originY, resultList.originY + resultList.contentHeight - resultList.height);
            const overhang = item.y + item.height - (resultList.contentY + resultList.height);
            if (overhang > 0) resultList.contentY = Math.min(resultList.contentY + overhang, maxY);
        }
        if (selectedIndex > 0) {
            const underhang = resultList.contentY - item.y;
            if (underhang > 0) resultList.contentY = Math.max(resultList.contentY - underhang, resultList.originY);
        }
    }

    function pageRows() {
        const height = rowHeightFor(filterText ? "x" : "");
        return Math.max(1, Math.floor((resultList.height + look.row.spacing) / (height + look.row.spacing)));
    }

    function select(delta) {
        if (displayModel.count === 0) return;
        disarmPointer();
        if (!cursorActive) {
            cursorActive = true;
            selectedIndex = delta < 0 ? displayModel.count - 1 : 0;
        } else if (Math.abs(delta) === 1) {
            // Single steps wrap around; the plate glides unless it wrapped.
            const next = (selectedIndex + delta + displayModel.count) % displayModel.count;
            if (Math.abs(next - selectedIndex) !== 1) snapPlate();
            selectedIndex = next;
        } else {
            snapPlate();
            selectedIndex = Math.max(0, Math.min(displayModel.count - 1, selectedIndex + delta));
        }
        revealCursor();
    }

    function snapPlate() {
        cursorPlate.snap = true;
        Qt.callLater(() => { cursorPlate.snap = false; });
    }

    // Hover moves the cursor only once the pointer has moved since the
    // list last changed under it, so a resting pointer steals nothing;
    // MenuModel.pointerMoved judges a motion.
    property bool pointerArmed: false
    property point pointerLast: Qt.point(-1, -1)

    function disarmPointer() {
        pointerArmed = false;
        pointerLast = Qt.point(-1, -1);
    }

    function selectFromPointer(index, item, mouse) {
        const at = item.mapToItem(root, mouse.x, mouse.y);
        if (!pointerArmed) {
            const moved = MenuModel.pointerMoved(pointerLast, at);
            pointerLast = at;
            if (!moved) return;
            pointerArmed = true;
        }
        cursorActive = true;
        selectedIndex = index;
    }

    // Super with W, A, S and D moves as the arrows do, for a keyboard
    // whose compositor passes them through.
    function superNavigate(key) {
        if (key === Qt.Key_W) select(-1);
        else if (key === Qt.Key_S) select(1);
        else if (key === Qt.Key_A) {
            if (openWithTarget) leaveOpenWith();
            else if (!filterText) goBack();
        } else if (key === Qt.Key_D) {
            if (cursorActive && displayModel.count > 0) activateIndex(selectedIndex);
        } else return false;
        return true;
    }

    // ------------------------------------------------------------ geometry

    function rowHeightFor(detail) {
        if (requestMode) return detail ? look.row.detailHeight : look.row.height;
        return filterText ? look.row.detailHeight : look.row.height;
    }

    function availableRowsHeight() {
        const top = !requestMode ? centeredTop : (cardTop >= 0 ? cardTop : look.card.margin);
        const chrome = look.card.padding * 2 + look.header.height + look.card.gap;
        let available = height - top - look.card.margin - chrome;
        if (!requestMode) available = Math.min(available, Math.round(height * look.card.tallest) - chrome);
        if (requestMode && requestMaxHeight > 0) available = Math.min(available, requestMaxHeight);
        return available;
    }

    // Every row when they fit; otherwise the card ends on a whole row and
    // the scrollbar marks the overflow.
    function foldedHeight(totals, available) {
        if (totals.length === 0) return look.row.height;
        if (totals[totals.length - 1] <= available) return totals[totals.length - 1];
        let full = 0;
        while (full < totals.length && totals[full] <= available) full++;
        return full > 0 ? totals[full - 1] : Math.max(available, look.row.height);
    }

    function rowListHeight(serial) {
        if (mode === "input") return 0;
        if (displayModel.count === 0) return searching && !requestMode ? look.row.height : 0;
        const totals = [];
        let total = 0;
        for (let i = 0; i < displayModel.count; i++) {
            if (i > 0) total += look.row.spacing;
            total += rowHeightFor(displayModel.get(i).detail);
            totals.push(total);
        }
        return foldedHeight(totals, availableRowsHeight());
    }

    readonly property int cardWidth: Math.min(requestMode ? requestWidth : look.card.width, width - 2 * look.card.margin)
    readonly property int visibleRowsHeight: rowListHeight(layoutSerial)
    readonly property int cardHeight: Math.min(look.card.padding * 2 + look.header.height + (visibleRowsHeight > 0 ? look.card.gap + visibleRowsHeight : 0), height - 2 * look.card.margin)
    // A picker's first keystroke freezes its top line, so it grows down
    // instead of re-centring; the launcher always sits on its fixed line.
    property int cardTop: -1
    readonly property int centeredTop: requestMode ? Math.max(look.card.margin, Math.round((height - cardHeight) / 2)) : Math.round(height * look.card.top)
    readonly property int effectiveCardTop: requestMode && cardTop >= 0 ? cardTop : centeredTop

    function freezeCardTop() {
        if (opened && cardTop < 0) cardTop = effectiveCardTop;
    }

    // ------------------------------------------------------------ drawing

    // A click outside the card closes it.
    // pointer-cursor-exempt: a press here is a click away from the card, not a control
    MouseArea {
        anchors.fill: parent
        onClicked: root.cancel()
    }

    GlassSurface {
        id: card
        look: root.look
        width: root.cardWidth
        height: Math.min(root.cardHeight, root.height - root.look.card.margin - root.effectiveCardTop)
        radius: Math.min(height / 2, root.look.card.radius)
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.effectiveCardTop + lift
        padding: root.look.card.padding
        shadowCached: false
        transformOrigin: Item.Top
        opacity: 0
        property real lift: 0
        property bool entered: false
        property bool closing: false
        // Height animates only once the card is on screen, so it never
        // shrinks from an earlier size as it opens.
        property bool settled: false

        Behavior on height {
            enabled: card.settled
            Anim { duration: root.look.motion.duration.medium2; curve: root.look.motion.curve.standard }
        }

        // Start values live here rather than as `from:`, so a reopen during
        // the exit fade continues from where the card is.
        function enter() {
            entered = true;
            opacity = 0;
            scale = root.look.card.enterScale;
            lift = -root.look.card.lift;
            cardEntrance.restart();
            Qt.callLater(() => { card.settled = true; });
        }

        ParallelAnimation {
            id: cardEntrance
            Anim { target: card; property: "opacity"; to: 1; duration: root.look.motion.duration.short4; curve: root.look.motion.curve.standard }
            Anim { target: card; property: "scale"; to: 1; duration: root.look.motion.duration.medium4; curve: root.look.motion.curve.emphasizedDecel }
            Anim { target: card; property: "lift"; to: 0; duration: root.look.motion.duration.medium4; curve: root.look.motion.curve.emphasizedDecel }
        }

        ParallelAnimation {
            id: cardExit
            Anim { target: card; property: "opacity"; to: 0; duration: root.look.motion.duration.short3; curve: root.look.motion.curve.emphasizedAccel }
            Anim { target: card; property: "scale"; to: root.look.card.exitScale; duration: root.look.motion.duration.short3; curve: root.look.motion.curve.emphasizedAccel }
            onFinished: {
                if (!card.closing) return;
                card.closing = false;
                Qt.callLater(root.hideSurface);
            }
        }

        // pointer-cursor-exempt: it holds the presses on the card, so they never reach the click-away area
        MouseArea {
            anchors.fill: parent
            onClicked: {}
        }

        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
                event.accepted = root.handleKey(event);
            }
        }

        Column {
            anchors.fill: parent
            anchors.margins: card.contentInset
            spacing: root.look.card.gap

            Item {
                width: parent.width
                height: root.look.header.height

                SearchGlyph {
                    id: searchGlyph
                    look: root.look
                    anchors.left: parent.left
                    anchors.leftMargin: root.look.header.glyphInset
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: root.searching ? root.look.search.active : root.look.search.idle
                    Behavior on opacity {
                        Anim { duration: root.look.motion.duration.short4; curve: root.look.motion.curve.standard }
                    }
                }

                Text {
                    id: headerText
                    textFormat: Text.PlainText
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: root.look.header.textGap
                    anchors.right: menuButton.visible ? menuButton.left : parent.right
                    anchors.rightMargin: root.look.header.textInset
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.openWithTarget ? "Open \u201c" + root.openWithTarget.name + "\u201d with\u2026"
                        : root.filterText || (root.requestMode ? root.prompt : (root.spotlightRoot || !root.items[root.activeMenu] ? "Search" : (root.items[root.activeMenu].title || root.items[root.activeMenu].label)))
                    color: root.look.text.foreground
                    opacity: root.filterText ? 1 : root.look.text.header.idle
                    font.family: root.look.font.family
                    font.pixelSize: root.look.text.header.size
                    font.letterSpacing: root.look.text.header.letterSpacing
                    style: Text.Raised
                    styleColor: root.look.text.shadow
                    elide: Text.ElideLeft
                }

                Caret {
                    id: caret
                    look: root.look
                    height: Math.round(headerText.font.pixelSize * root.look.caret.height)
                    anchors.verticalCenter: parent.verticalCenter
                    x: headerText.x + (root.filterText ? Math.min(headerText.contentWidth, headerText.width) + root.look.caret.gap : -root.look.caret.rest)
                    running: root.opened
                    lit: root.searching
                    Behavior on x {
                        Anim { duration: root.look.motion.duration.short2; curve: root.look.motion.curve.standard }
                    }
                }

                IconButton {
                    id: menuButton
                    look: root.look
                    visible: root.spotlightRoot
                    anchors.right: parent.right
                    anchors.rightMargin: root.look.header.buttonInset
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.showCategories
                    onClicked: root.toggleCategories()

                    MenuGlyph {
                        anchors.centerIn: parent
                        look: root.look
                        open: root.showCategories
                        emphasis: menuButton.hovered || root.showCategories ? root.look.menuGlyph.active : root.look.menuGlyph.idle
                    }
                }

                // The hairline between the field and its results.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.bottom
                    anchors.topMargin: root.look.header.dividerOffset
                    anchors.leftMargin: -root.look.card.padding
                    anchors.rightMargin: -root.look.card.padding
                    height: root.look.glass.hairlineWidth
                    color: root.look.glass.divider
                    opacity: root.visibleRowsHeight > 0 ? 1 : 0
                    Behavior on opacity {
                        Anim { duration: root.look.motion.duration.short4; curve: root.look.motion.curve.standard }
                    }
                }
            }

            Item {
                width: parent.width
                height: root.visibleRowsHeight

                ListView {
                    id: resultList
                    // No picks during the exit fade.
                    enabled: root.opened
                    anchors.fill: parent
                    model: displayModel
                    clip: true
                    spacing: root.look.row.spacing
                    boundsBehavior: Flickable.StopAtBounds

                    // One plate glides between rows.
                    Highlight {
                        id: cursorPlate
                        look: root.look
                        parent: resultList.contentItem
                        property real targetY: 0
                        property real targetHeight: root.look.row.height
                        // Snap rather than glide when the list was rebuilt or
                        // the cursor jumped.
                        property bool snap: true
                        z: -1
                        width: resultList.width
                        y: targetY
                        height: targetHeight
                        shown: root.cursorActive && displayModel.count > 0
                        onShownChanged: if (!shown) snap = true
                        Behavior on y {
                            enabled: !cursorPlate.snap
                            Anim { duration: root.look.motion.duration.medium1; curve: root.look.motion.curve.emphasizedDecel }
                        }
                        Behavior on height {
                            enabled: !cursorPlate.snap
                            Anim { duration: root.look.motion.duration.medium1; curve: root.look.motion.curve.standard }
                        }
                    }

                    delegate: LauncherRow {
                        look: root.look
                        launcher: root
                        plate: cursorPlate
                        width: ListView.view.width
                    }
                }

                Text {
                    anchors.fill: parent
                    visible: root.searching && displayModel.count === 0 && !(root.fileMode && fileSearch.busy) && !root.openWithTarget && !root.requestMode
                    textFormat: Text.PlainText
                    text: "No results"
                    color: root.look.text.foreground
                    opacity: root.look.text.empty.opacity
                    font.family: root.look.font.family
                    font.pixelSize: root.look.text.empty.size
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                // A slim scrollbar that widens under the pointer and drags.
                Item {
                    id: scrollbar
                    readonly property real ratio: resultList.contentHeight <= 0 ? 1 : resultList.height / resultList.contentHeight
                    readonly property real travel: Math.max(1, resultList.contentHeight - resultList.height)
                    readonly property bool active: scrollMouse.containsMouse || scrollMouse.pressed
                    visible: ratio < 1
                    anchors.right: parent.right
                    anchors.rightMargin: -root.look.scrollbar.width
                    width: root.look.scrollbar.width
                    height: Math.max(root.look.scrollbar.minHeight, resultList.height * ratio)
                    y: (resultList.height - height) * Math.max(0, Math.min(1, (resultList.contentY - resultList.originY) / travel))

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: scrollbar.active ? root.look.scrollbar.wide : root.look.scrollbar.thin
                        height: parent.height
                        radius: root.look.radius.full
                        color: root.look.text.foreground
                        opacity: scrollbar.active ? root.look.scrollbar.active : (resultList.moving ? root.look.scrollbar.moving : root.look.scrollbar.idle)
                        Behavior on width {
                            Anim { duration: root.look.motion.duration.short4; curve: root.look.motion.curve.standard }
                        }
                        Behavior on opacity {
                            Anim { duration: root.look.motion.duration.medium2; curve: root.look.motion.curve.standard }
                        }
                    }

                    // pointer-cursor-exempt: a scroll bar keeps the arrow, as Qt's own scroll bars do
                    MouseArea {
                        id: scrollMouse
                        property real grab: 0
                        anchors.fill: parent
                        hoverEnabled: true
                        preventStealing: true
                        onPressed: mouse => { grab = mouse.y; }
                        onPositionChanged: mouse => {
                            if (!pressed) return;
                            const track = Math.max(1, resultList.height - scrollbar.height);
                            const top = scrollbar.y + mouse.y - grab;
                            resultList.contentY = resultList.originY + Math.max(0, Math.min(1, top / track)) * scrollbar.travel;
                        }
                    }
                }
            }
        }
    }

    EdgeLight {
        id: edgeLight
        look: root.look
        follow: card
        active: root.searching
    }

    ContextMenu {
        id: fileFlyout
        look: root.look
        property string targetPath: ""
        function dismiss() {
            targetPath = "";
            close();
        }
        onTriggered: id => {
            const path = targetPath;
            if (id === "reveal" || id === "copy") root.runOpenWith(id, path);
            else if (id.indexOf("app:") === 0) root.runOpenWith(id.substring(4), path);
        }
    }

    // ------------------------------------------------------------ keys

    // One key press, answered true when the launcher took it.
    function handleKey(event) {
        const key = event.key;
        const plain = event.modifiers === Qt.NoModifier;
        const enter = key === Qt.Key_Return || key === Qt.Key_Enter;
        if ((event.modifiers & Qt.MetaModifier) && superNavigate(key)) return true;
        if (fileFlyout.opened && key === Qt.Key_Escape) {
            fileFlyout.close();
            return true;
        }
        if (openWithTarget && (key === Qt.Key_Escape || key === Qt.Key_Left || (key === Qt.Key_Backspace && plain))) {
            leaveOpenWith();
            return true;
        }
        if (enter && (event.modifiers & Qt.ShiftModifier) && fileMode && !openWithTarget && cursorActive && displayModel.count > 0) {
            const pick = displayModel.get(selectedIndex);
            if (pick.kind === "file" || pick.kind === "folder") showOpenWith(pick.path, pick.label);
            return true;
        }
        if (key === Qt.Key_B && event.modifiers === Qt.ControlModifier && !requestMode) {
            if (spotlightRoot) toggleCategories();
            return true;
        }
        if (key === Qt.Key_Delete) {
            requestRemove();
            return true;
        }
        if (key === Qt.Key_Escape) {
            if (filterText) setFilter("");
            else cancel();
            return true;
        }
        if (filterText && key === Qt.Key_Backspace && plain) {
            setFilter(filterText.slice(0, -1));
            caret.nudge();
            return true;
        }
        if (filterText && ((key === Qt.Key_Backspace && event.modifiers === Qt.ControlModifier) || (key === Qt.Key_W && event.modifiers === Qt.ControlModifier))) {
            setFilter(MenuModel.dropWord(filterText));
            caret.nudge();
            return true;
        }
        if (key === Qt.Key_U && event.modifiers === Qt.ControlModifier) {
            setFilter("");
            return true;
        }
        if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && !filterText) {
            goBack();
            return true;
        }
        if (key === Qt.Key_Up) { select(-1); return true; }
        if (key === Qt.Key_Down) { select(1); return true; }
        if (key === Qt.Key_PageUp) { select(-pageRows()); return true; }
        if (key === Qt.Key_PageDown) { select(pageRows()); return true; }
        if (enter || key === Qt.Key_Right) {
            if (mode === "input") finishAndDismiss(filterText);
            else if (requestMode) {
                if (displayModel.count > 0) activateIndex(cursorActive ? selectedIndex : 0);
            } else if (cursorActive) activateIndex(selectedIndex);
            else if (displayModel.count > 0) cursorActive = true;
            return true;
        }
        const text = event.text;
        if (text && text.length === 1 && text.charCodeAt(0) >= 32 && text.charCodeAt(0) !== 127 && (plain || event.modifiers === Qt.ShiftModifier)) {
            setFilter(filterText + text);
            caret.nudge();
            return true;
        }
        return false;
    }
}
