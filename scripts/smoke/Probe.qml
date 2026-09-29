import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Core
import qs.Commons
import "Commons/Tokens.js" as Tokens
import "Commons/ThemeLogic.js" as ThemeLogic

// Loaded only into the sandbox copy. It observes the shipped objects and
// owns test setup, so tests add no callable methods to the shipped shell.
Scope {
    id: root
    property int builds: 0
    property int frames: 0
    property int changes: 0
    property int userLoads: 0
    property var previousRows: []
    // What the shell did from its start, in order, for rows/start-order.sh:
    // ["scan"] per ended scan and ["scan-turn-end"] once the event loop has
    // run past the turn that ended it, ["frame", n] when a bar window
    // presents its first frame, n the bar windows presented so far,
    // ["service", id] per service the core built, ["release", reason] when
    // ServiceGate releases the services, and ["follow"] per follow job the
    // theme runner queued.
    property var startOrder: []
    property var presentedWindows: []
    property var followJobs: []
    property var heldField: null
    property var heldEditor: null
    property string grab: ""
    // A plugin instance's status provider, kept past the instance, so a row
    // writes through it once the core has retired the instance.
    property var heldStatus: null
    // A copy of the core's ThemeRunner built from a file for a control, and
    // what each of its members' callbacks received: verb -> { count,
    // result }. The copy's context is never torn down.
    property var runnerCopy: null
    property var runnerAnswers: ({})
    // Copies of a core popup, a qs.Ui overlay or SummonPopup, built from a
    // file a row writes beside the shipped one for a dismissal control, by
    // the name the row gives each.
    property var popupCopies: ({})
    readonly property var runnerContext: ({ id: "smoke-runner-copy", onDispose: () => () => {} })

    // Call the copy's member VERB with ARGS, then `done`, then any EXTRA,
    // its answers kept by verb; the member's reply, `ok` for none.
    function callRunner(verb, args, ...extra) {
        if (root.runnerCopy === null) return "absent";
        const done = result => {
            const next = Object.assign({}, root.runnerAnswers);
            next[verb] = { count: (verb in root.runnerAnswers ? root.runnerAnswers[verb].count : 0) + 1, result: result };
            root.runnerAnswers = next;
        };
        const reply = root.runnerCopy[verb](root.runnerContext, ...args, done, ...extra);
        return reply === undefined ? "ok" : String(reply);
    }

    function note(event) { root.startOrder = root.startOrder.concat([event]); }

    Connections {
        target: Plugins
        function onBuiltChanged() {
            const rows = [];
            for (const key of Object.keys(Plugins.built))
                for (const row of Plugins.built[key])
                    if (row.origin === "core") rows.push(row);
            for (const row of rows)
                if (root.previousRows.indexOf(row) === -1) {
                    root.builds += 1;
                    if (row.kind === "service") root.note(["service", row.id]);
                }
            root.previousRows = rows;
        }
    }
    Connections {
        target: Registry
        function onScanFinished() {
            root.note(["scan"]);
            Qt.callLater(() => root.note(["scan-turn-end"]));
        }
    }
    Connections {
        target: ServiceGate
        function onReleaseChanged() { root.note(["release", ServiceGate.release]); }
    }
    Connections {
        target: Capabilities.themes
        function onJobsChanged() {
            for (const job of Capabilities.themes.jobs)
                if (job.verb === "follow" && root.followJobs.indexOf(job) === -1) {
                    root.followJobs = root.followJobs.concat([job]);
                    root.note(["follow"]);
                }
        }
    }
    Connections {
        target: Config
        function onEffectiveChanged() { root.changes += 1; }
    }
    Connections {
        target: Config.smokeUserView
        function onLoaded() { root.userLoads += 1; }
        function onLoadFailed(error) { root.userLoads += 1; }
    }
    Variants {
        model: {
            const windows = [];
            for (const key of Object.keys(Plugins.built))
                for (const row of Plugins.built[key])
                    if (row.origin === "core" && row.kind === "bar") windows.push(row.instance.Window.window);
            return windows;
        }
        Connections {
            required property var modelData
            target: modelData
            function onFrameSwapped() {
                root.frames += 1;
                if (root.presentedWindows.indexOf(modelData) !== -1) return;
                root.presentedWindows = root.presentedWindows.concat([modelData]);
                root.note(["frame", root.presentedWindows.length]);
            }
        }
    }

    FileView { id: uiModule; path: Qt.resolvedUrl("Ui/qmldir"); blockLoading: true }

    function instance(hostKey, id) {
        const rows = Plugins.built[hostKey] || [];
        const row = rows.find(r => r.id === id);
        return row === undefined ? null : row.instance;
    }

    function descendants(item) {
        const found = [item];
        for (let i = 0; i < found.length; i++)
            for (const child of found[i].children || []) found.push(child);
        return found;
    }

    function shownScrollAreas(item) {
        const shown = child => { for (let at = child; at !== null; at = at.parent) if (!at.visible) return false; return true; };
        const isScroll = child => child.bar !== undefined && child.contentY !== undefined;
        const nested = child => {
            for (let at = child.parent; at !== null && at !== item; at = at.parent)
                if (isScroll(at) && shown(at)) return true;
            return false;
        };
        return root.descendants(item).filter(child => isScroll(child) && shown(child) && !nested(child) && child.mapToItem(item, 0, 0).x >= 0 && child.mapToItem(item, 0, 0).x < item.width);
    }

    // The first visible, enabled item named `type` whose `text` is `text`
    // under an instance, or null.
    function textItem(hostKey, id, type, text) {
        const item = root.instance(hostKey, id);
        if (item === null) return null;
        const found = root.descendants(item).find(child => root.typeName(child) === type && child.text === text && child.visible && child.enabled);
        return found === undefined ? null : found;
    }

    // The first visible, enabled item named `type` whose `property` reads
    // `value` in a plugin's layer copies, sorted by screen, or null.
    function layerItem(id, type, property, value) {
        for (const entry of Layers.entries.filter(e => e.pluginId === id))
            for (const screen of Object.keys(entry.screens).sort()) {
                const found = root.descendants(entry.screens[screen]).find(child => root.typeName(child) === type && String(child[property]) === value && child.visible && child.enabled);
                if (found !== undefined) return found;
            }
        return null;
    }

    // The first visible, enabled item named `type` whose `text`, or `name`
    // for an icon, is `text` inside the first visible item named
    // `scopeType` that draws `scopeText`, under an instance, or null: one
    // row's button among rows that each draw a button with the same text.
    function scopedItem(hostKey, id, scopeType, scopeText, type, text) {
        const item = root.instance(hostKey, id);
        if (item === null) return null;
        const draws = node => root.descendants(node).some(child => child instanceof Text && child.visible && child.text === scopeText);
        const scope = root.descendants(item).find(child => root.typeName(child) === scopeType && child.visible && draws(child));
        if (scope === undefined) return null;
        const found = root.descendants(scope).find(child => root.typeName(child) === type && (child.text === text || child.name === text) && child.visible && child.enabled);
        return found === undefined ? null : found;
    }

    // The window box of the first visible item named `type` under an
    // instance whose `text`, or `label` for an icon button, is `text`, and
    // enabled when `enabledOnly` holds, or "absent".
    function labelledBox(hostKey, id, type, text, enabledOnly) {
        const item = root.instance(hostKey, id);
        if (item === null) return "absent";
        const found = root.descendants(item).find(child => root.typeName(child) === type && (child.text === text || child.label === text) && child.visible && (child.enabled || !enabledOnly));
        return found === undefined ? "absent" : JSON.stringify(root.windowBox(found));
    }

    function fieldOf(panel, id, key) {
        return descendants(panel).find(item => item.pluginId === id && item.key === key && typeof item.apply === "function") || null;
    }

    function geometry(item) {
        if (item === null) return "absent";
        const at = item.mapToGlobal(0, 0);
        return JSON.stringify([at.x, at.y, item.width, item.height]);
    }

    // An item's box in its own window's coordinates, as [x, y, w, h]: a
    // layer surface the compositor centres knows no place of its own on the
    // screen, so a row adds the layer's position from `hyprctl layers`.
    function windowBox(item) {
        const at = item.mapToItem(null, 0, 0);
        return [at.x, at.y, item.width, item.height];
    }

    // An item's type name, with the engine's suffixes for a QML-defined type
    // and for one extended in place (a delegate that declares a property of
    // its own) removed.
    function typeName(item) {
        return String(item).split("(")[0].replace(/(_QML(TYPE)?_\d+)+$/, "");
    }

    function read(hostKey, id, property) {
        const item = instance(hostKey, id);
        if (item === null) return "absent";
        const value = item[property];
        const json = JSON.stringify(value);
        return json === undefined ? "undefined" : json;
    }

    function invoke(hostKey, id, name, arg) {
        const item = instance(hostKey, id);
        if (item === null) return "absent";
        if (name === "applySetting") {
            const a = JSON.parse(arg);
            return item.writeSetting(a.id, a.key, a.value);
        }
        if (name === "applyKey") {
            // A drawn Keys row's edit, as the row emits it: `key` absent
            // is a reset.
            const a = JSON.parse(arg);
            const row = descendants(item).find(child => child.pluginId === a.id && child.bind !== undefined && child.bind.shortcut === a.shortcut && typeof child.applyKey === "function");
            if (row === undefined) return "absent";
            row.applyKey("key" in a ? a.key : undefined);
            return "applied";
        }
        if (name === "applyField" || name === "holdField") {
            const a = JSON.parse(arg);
            const field = fieldOf(item, a.id, a.key);
            if (field === null) return "absent";
            if (name === "applyField") { field.apply(a.value); return "applied"; }
            const editor = descendants(field).find(child => child instanceof TextInput);
            if (editor === undefined) return "absent";
            editor.forceActiveFocus();
            editor.text = a.text;
            editor.cursorPosition = 1;
            heldField = { id: a.id, key: a.key, field: field };
            heldEditor = editor;
            return JSON.stringify(windowBox(editor));
        }
        if (name === "heldFieldState") {
            if (heldField === null || heldEditor === null) return "absent";
            return JSON.stringify({ same: fieldOf(item, heldField.id, heldField.key) === heldField.field,
                focus: heldEditor.focus, activeFocus: heldEditor.activeFocus,
                text: heldEditor.text, cursor: heldEditor.cursorPosition });
        }
        if (typeof item[name] !== "function") return "no-function";
        const result = item[name](arg);
        return result === undefined ? "" : String(result);
    }

    // A token's QML value as JSON.
    function themeValue(path) {
        let node = Theme;
        for (const key of path.split(".")) {
            if (node === undefined || node === null) return "absent";
            node = node[key];
        }
        return node === undefined ? "absent" : JSON.stringify(node);
    }

    // Write into a published group the way a careless plugin would; answers
    // the value read back after the write, so the row proves nothing moved.
    function themeWrite(path, value) {
        const keys = path.split(".");
        let node = Theme;
        for (const key of keys.slice(0, -1)) node = node[key];
        try { node[keys[keys.length - 1]] = value; } catch (e) {}
        return themeValue(path);
    }

    IpcHandler {
        target: "smoke"
        // Every top-level group of the token table that Theme does not
        // publish as a frozen object, so an empty list is the pass.
        function themeUnpublished(): string {
            return JSON.stringify(Object.keys(Tokens.TOKENS).filter(group => typeof Theme[group] !== "object" || Theme[group] === null || !Object.isFrozen(Theme[group])));
        }
        function themeValue(path: string): string { return root.themeValue(path); }
        // Each surface the layer host built for a plugin, sorted by screen:
        // [screen, takes no keyboard, on the overlay layer, clear of
        // reserved space].
        function layerSurfaces(id: string): string {
            const out = [];
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const name of Object.keys(entry.screens).sort()) {
                    const win = entry.screens[name].QsWindow.window;
                    out.push([name, win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, win.WlrLayershell.layer === WlrLayer.Overlay, win.exclusionMode === ExclusionMode.Normal]);
                }
            return JSON.stringify(out);
        }
        // The box of the first visible, enabled item named `type` whose
        // `property` reads `value` in a plugin's layer copies, sorted by
        // screen, as [x, y, w, h] in its window, or "absent". A layer the
        // compositor places knows no position of its own, so a row adds the
        // layer's position from `hyprctl layers`.
        function layerItemGeometry(id: string, type: string, property: string, value: string): string {
            const found = root.layerItem(id, type, property, value);
            return found === null ? "absent" : JSON.stringify(root.windowBox(found));
        }
        // Whether that item reports the pointer over it: "true", "false",
        // or "absent" with no such item, as itemHovered answers for an
        // instance's item.
        function layerItemHovered(id: string, type: string, property: string, value: string): string {
            const found = root.layerItem(id, type, property, value);
            return found === null ? "absent" : String(found.hovered === true);
        }
        // Every item of a type in a plugin's layer copies, sorted by screen:
        // [screen, [x, y, width, height] in its window, { property: value }]
        // for each property named in the comma list.
        function layerItems(id: string, type: string, properties: string): string {
            const names = properties === "" ? [] : properties.split(",");
            const out = [];
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const screen of Object.keys(entry.screens).sort())
                    for (const item of root.descendants(entry.screens[screen]).filter(i => root.typeName(i) === type)) {
                        const at = item.mapToGlobal(0, 0);
                        const values = {};
                        // A colour reads as its #aarrggbb name, not its channels.
                        for (const name of names) values[name] = item[name] !== null && typeof item[name] === "object" && "hslHue" in item[name] ? item[name].toString() : item[name];
                        out.push([screen, [Math.round(at.x), Math.round(at.y), Math.round(item.width), Math.round(item.height)], values]);
                    }
            return JSON.stringify(out);
        }
        // Saves the first item of a type in a plugin's layer copies whose
        // property reads the value to PATH as a PNG: the item and its
        // children as its window draws them, without the items under or
        // over it. Answers grabbing, absent, or refused when the item cannot
        // be grabbed now; grabbed() answers the outcome.
        function grabLayerItem(id: string, type: string, property: string, value: string, path: string): string {
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const screen of Object.keys(entry.screens).sort())
                    for (const item of root.descendants(entry.screens[screen]).filter(i => root.typeName(i) === type && String(i[property]) === value)) {
                        root.grab = "pending " + path;
                        if (!item.grabToImage(result => root.grab = (result.saveToFile(path) ? "saved " : "unsaved ") + path)) {
                            root.grab = "";
                            return "refused";
                        }
                        return "grabbing";
                    }
            return "absent";
        }
        // pending, saved or unsaved, and the path, for the last grab.
        function grabbed(): string { return root.grab; }
        // Every shader effect in a plugin's layer copies: [screen, its
        // fragment shader's URL, whether it compiled].
        function layerShaders(id: string): string {
            const out = [];
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const screen of Object.keys(entry.screens).sort())
                    for (const item of root.descendants(entry.screens[screen]).filter(i => i instanceof ShaderEffect))
                        out.push([screen, String(item.fragmentShader), item.status === ShaderEffect.Compiled]);
            return JSON.stringify(out);
        }
        // A service's ListModel property as a list of rows, each the roles
        // named in the comma list.
        function modelRows(id: string, property: string, roles: string): string {
            const model = root.instance("service", id);
            if (model === null) return "absent";
            const list = model[property];
            const out = [];
            for (let i = 0; i < list.count; i++) {
                const row = list.get(i);
                out.push(roles.split(",").map(r => row[r]));
            }
            return JSON.stringify(out);
        }
        function toastCloseGeometry(index: int): string { return Plugins.hosts.toast === undefined ? "absent" : Plugins.hosts.toast.closeGeometry(index); }
        function toastWindowGeometry(index: int): string { return Plugins.hosts.toast === undefined ? "absent" : Plugins.hosts.toast.toastWindowGeometry(index); }
        // The requirement notice's dialog: whether an item in it holds the
        // keyboard focus, and what it draws as { title, message, rows,
        // actions, busy }, `rows` the visible lines under the message.
        function noticeFocused(): bool {
            const dialog = Plugins.hosts.notice === undefined ? null : Plugins.hosts.notice.dialog;
            return dialog !== null && root.descendants(dialog).some(child => child.activeFocus);
        }
        // The dialog's box, or its title's for `title`, in the notice
        // window's coordinates, or "absent" while no notice shows.
        function noticeWindowGeometry(part: string): string {
            const dialog = Plugins.hosts.notice === undefined ? null : Plugins.hosts.notice.dialog;
            if (dialog === null) return "absent";
            if (part === "card") return JSON.stringify(root.windowBox(dialog));
            if (part !== "title") return "refused: part=" + part + " want=card|title";
            const title = root.descendants(dialog).find(child => root.typeName(child) === "Label" && child.visible && child.text === dialog.title);
            return title === undefined ? "absent" : JSON.stringify(root.windowBox(title));
        }
        function noticeDrawn(): string {
            const dialog = Plugins.hosts.notice === undefined ? null : Plugins.hosts.notice.dialog;
            if (dialog === null) return "absent";
            const labels = root.descendants(dialog).filter(child => root.typeName(child) === "Label" && child.visible);
            return JSON.stringify({
                title: dialog.title,
                message: dialog.message,
                rows: labels.map(label => label.text).filter(text => text !== dialog.title && text !== dialog.message && !dialog.entries.some(entry => entry.label === text)),
                actions: dialog.entries.map(entry => entry.label),
                busy: dialog.busy
            });
        }
        // The components of qs.Ui, read from its qmldir, that the gallery
        // draws no instance of; an empty list is the pass. A QML-defined
        // type prints as `<Name>_QMLTYPE_<n>(...)`. PointerCursor is a
        // pointer handler, which no item list holds; every gallery control
        // declares one. ListEntrance is a transform, read from each item's
        // `transform` list.
        function galleryMissing(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const names = [];
            for (const line of uiModule.text().split("\n")) {
                const m = /^(\w+) 1\.0 \S+$/.exec(line);
                if (m !== null && m[1] !== "BarWidget" && m[1] !== "PointerCursor") names.push(m[1]);
            }
            if (names.length < 20) return "qmldir-read-broken=" + names.length;
            const seen = {};
            for (const child of root.descendants(item.examples))
                for (const drawn of [child].concat(Array.from(child.transform || []))) {
                    const m = /^(\w+)_QMLTYPE_/.exec(String(drawn));
                    if (m !== null) seen[m[1]] = true;
                }
            return JSON.stringify(names.filter(name => !seen[name]));
        }
        // Examples drawn past the gallery's right edge, so a row that does
        // not wrap to the panel names itself; an empty list is the pass.
        function galleryOverflow(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const out = [];
            for (const child of root.descendants(item.examples)) {
                if (!child.visible || child.width === undefined || child.width === 0) continue;
                const right = child.mapToItem(item, child.width, 0).x;
                if (right > item.width + 1) out.push(String(child).split("(")[0] + ":" + Math.round(right));
            }
            return JSON.stringify(out);
        }
        // Scrolls the one shown ScrollArea under an instance to `y`, held
        // inside its content, so scripts/sandbox-shots.sh captures each
        // page of a scrolling panel. Answers [contentY, contentHeight,
        // height], or shown-scroll-areas=N when the target is ambiguous.
        function scrollTo(hostKey: string, id: string, y: int): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const areas = root.shownScrollAreas(item);
            if (areas.length !== 1) return "shown-scroll-areas=" + areas.length;
            const flick = areas[0];
            flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
            return JSON.stringify([flick.contentY, flick.contentHeight, flick.height]);
        }
        function galleryHeadings(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const drawn = root.descendants(item.examples).filter(child => /^SectionHeader_QMLTYPE_/.test(String(child)) && child.width > 0 && child.height > 0);
            return String(drawn.length);
        }
        // A colour one gallery example draws with, read as a property: the
        // first item named `type` in the section under the SectionHeader
        // reading `section`, through `property`, a dotted path. Written as
        // ThemeLogic writes a resolved colour, `#rrggbbaa`, so a row compares
        // it with the package's token without reading a frame.
        function galleryColour(hostKey: string, id: string, section: string, type: string, property: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const typeOf = child => String(child).split("_QMLTYPE_")[0];
            const header = root.descendants(item.examples).find(child => typeOf(child) === "SectionHeader" && child.text === section);
            if (header === undefined) return "no-section";
            const siblings = header.parent.children;
            let at = 0;
            while (siblings[at] !== header) at++;
            for (at++; at < siblings.length && typeOf(siblings[at]) !== "SectionHeader"; at++) {
                const example = root.descendants(siblings[at]).find(child => typeOf(child) === type);
                if (example === undefined) continue;
                let value = example;
                for (const key of property.split(".")) value = value === null || value === undefined ? undefined : value[key];
                if (value === null || value === undefined || typeof value.a !== "number") return "not-colour";
                return ThemeLogic.formatColor(value);
            }
            return "no-example";
        }
        function themeWrite(path: string, value: string): string { return root.themeWrite(path, value); }
        function themeName(): string { return Theme.name; }
        function themeRevision(): int { return Theme.revision; }
        function fontAvailable(family: string): bool { return Qt.fontFamilies().indexOf(family) !== -1; }
        function buildCount(): int { return root.builds; }
        function frames(): int { return root.frames; }
        function startOrder(): string { return JSON.stringify(root.startOrder); }
        // A detached process the shell starts that runs until GATE exists,
        // for SECONDS at most, so it can outlive the shell and never the
        // row. It stands in for a long child of the shell, such as a
        // download, in rows/start-order.sh's instance lock readings: it
        // inherits the shell's descriptors, and holds the instance lock
        // only under a runner that hands the shell the lock's descriptor.
        function holdUntil(gate: string, seconds: int): string {
            Quickshell.execDetached(["timeout", String(seconds), "sh", "-c", 'until [ -e "$1" ]; do sleep 0.05; done', "sh", gate]);
            return "ok";
        }
        function configChanges(): int { return root.changes; }
        function configUserLoads(): int { return root.userLoads; }
        function failedBuilds(hostKey: string): int {
            return Object.keys(Plugins.failedBuilds).filter(key => JSON.parse(key)[0] === hostKey).length;
        }
        function configSettled(): bool { return !Config.smokeUserView.busy && !Config.reloadRequested; }
        function readInstance(hostKey: string, id: string, property: string): string { return root.read(hostKey, id, property); }
        function instanceGeometry(hostKey: string, id: string): string { return root.geometry(root.instance(hostKey, id)); }
        // Every item under an instance, the instance first, breadth first:
        // its type name as typeName writes it, its box in screen
        // coordinates, its implicit size, the index of its parent in the
        // list, a Label's role and a text's line height, at which only 1
        // makes a box its glyphs. A row measures alignment from it, so the
        // shipped item carries no readback of its own.
        function descendantGeometry(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const items = root.descendants(item);
            return JSON.stringify(items.map(child => {
                const at = child.mapToGlobal(0, 0);
                return {
                    type: root.typeName(child),
                    box: [at.x, at.y, child.width, child.height],
                    implicit: [child.implicitWidth, child.implicitHeight],
                    parent: items.indexOf(child.parent),
                    role: child.role,
                    lineHeight: child.lineHeight,
                    text: child.text
                };
            }));
        }
        // Every item named `type` under an instance, in tree order, as the
        // texts it draws: its visible, non-empty Text items depth first, so
        // a row reads a list item's title, its secondary line, its trailing
        // badges and then whatever follows it, as drawn now.
        function itemTexts(hostKey: string, id: string, type: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const texts = node => {
                const own = node instanceof Text && node.visible && node.text !== "" ? [node.text] : [];
                return own.concat(...Array.from(node.children || []).map(texts));
            };
            return JSON.stringify(root.descendants(item).filter(child => root.typeName(child) === type).map(texts));
        }
        // Every item named `type` under an instance, in tree order, as the
        // colours its visible descendants named `childType` fill with,
        // written as ThemeLogic writes a resolved colour, `#rrggbbaa`.
        function itemColours(hostKey: string, id: string, type: string, childType: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return JSON.stringify(root.descendants(item).filter(child => root.typeName(child) === type).map(found =>
                root.descendants(found).filter(child => child !== found && child.visible && root.typeName(child) === childType).map(child => ThemeLogic.formatColor(child.color))));
        }
        // The box of the first visible, enabled item named `type` whose
        // `text` is `text`, in screen coordinates, so a row can click it.
        function itemGeometry(hostKey: string, id: string, type: string, text: string): string {
            return root.geometry(root.textItem(hostKey, id, type, text));
        }
        // Whether that item reports the pointer over it: "true", "false",
        // or "absent" with no such item. The compositor routes a click by
        // where it has placed the surface, which can trail the layout
        // itemGeometry reads, so a row clicks once this reads "true".
        function itemHovered(hostKey: string, id: string, type: string, text: string): string {
            const found = root.textItem(hostKey, id, type, text);
            return found === null ? "absent" : String(found.hovered === true);
        }
        // The same for the first visible, enabled item named `type` whose
        // `label` is `label`, for an icon button, which draws no text.
        function labelledGeometry(hostKey: string, id: string, type: string, label: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === type && child.label === label && child.visible && child.enabled);
            return root.geometry(found === undefined ? null : found);
        }
        // Every Image under an instance, in tree order, as the local path it
        // draws, without a query ("" for none), its status (`null`, `ready`, `loading` or
        // `error`), its box's size, the size it decoded the file to, and
        // its requested source size, so a row reads what a background draws.
        function images(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const states = { [Image.Null]: "null", [Image.Ready]: "ready", [Image.Loading]: "loading", [Image.Error]: "error" };
            const local = url => url === "" ? "" : decodeURIComponent(url.replace(/^file:\/\//, "").replace(/\?.*$/, ""));
            return JSON.stringify(root.descendants(item).filter(child => child instanceof Image).map(image =>
                [local(image.source.toString()), states[image.status], [image.width, image.height], [image.implicitWidth, image.implicitHeight], [image.sourceSize.width, image.sourceSize.height]]));
        }
        // The screen the host handed an instance, as [width, height,
        // devicePixelRatio], the size in logical pixels, or "absent", so a
        // row reads the scale the shell started on.
        function screenOf(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || !item.screen) return "absent";
            return JSON.stringify([item.screen.width, item.screen.height, item.screen.devicePixelRatio]);
        }
        function hasWorkspaceAction(hostKey: string, id: string): bool {
            const item = root.instance(hostKey, id);
            if (item === null || !item.bar || !item.bar.shell) return false;
            const compositor = item.bar.shell.compositor;
            return compositor !== undefined && typeof compositor.focusWorkspace === "function";
        }
        function textOf(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            const label = item === null ? undefined : root.descendants(item).find(child => child instanceof Text);
            return label === undefined ? "absent" : JSON.stringify(label.text);
        }
        function drawnFields(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const counts = {};
            for (const row of item.plugins) counts[row.id] = 0;
            for (const field of root.descendants(item))
                if (typeof field.apply === "function" && field.pluginId !== undefined) counts[field.pluginId] += 1;
            return JSON.stringify(counts);
        }
        function childIndex(hostKey: string, id: string): int {
            const item = root.instance(hostKey, id);
            if (item === null || item.parent === null) return -1;
            for (let i = 0; i < item.parent.children.length; i++)
                if (item.parent.children[i] === item) return i;
            return -1;
        }
        function invokeInstance(hostKey: string, id: string, name: string, arg: string): string { return root.invoke(hostKey, id, name, arg); }
        // Every StatusRow under an instance, in tree order, as the type
        // names of its descendants that take an edit: a text input, a text
        // edit that is not read-only, a checkable control, or an item with
        // a setting's or a key's apply. A read-only row lists none.
        function statusRowInputs(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const takesEdit = child => child instanceof TextInput || (child instanceof TextEdit && !child.readOnly) || child.checkable === true || typeof child.apply === "function" || typeof child.applyKey === "function";
            return JSON.stringify(root.descendants(item).filter(child => root.typeName(child) === "StatusRow").map(row =>
                root.descendants(row).filter(child => child !== row && takesEdit(child)).map(child => root.typeName(child))));
        }
        // Keep an instance's `status` provider, answering `held` or `absent`.
        function holdStatus(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.shell === null || item.shell.status === undefined) return "absent";
            root.heldStatus = item.shell.status;
            return "held";
        }
        // The `doctor` capability of an instance: an offer for OWNER's
        // COMMANDS, comma-separated since qs reads a bracketed argument as a
        // list, and its `missing` as JSON.
        function doctorOffer(hostKey: string, id: string, owner: string, commands: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.shell === null || item.shell.doctor === undefined) return "absent";
            return item.shell.doctor.offer(owner, commands.split(","));
        }
        function doctorMissing(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.shell === null || item.shell.doctor === undefined) return "absent";
            return JSON.stringify(item.shell.doctor.missing);
        }
        // Publish a JSON value through the kept provider; its reply.
        function heldStatusSet(key: string, valueJson: string): string {
            return root.heldStatus === null ? "absent" : root.heldStatus.set(key, JSON.parse(valueJson));
        }
        // The first visible, enabled item named `type` under an instance
        // whose `text`, or `label` for an icon button, is `text`, as its
        // box in its window's coordinates, or "absent".
        // windowGeometry for the item scopedItem finds.
        function scopedWindowGeometry(hostKey: string, id: string, scopeType: string, scopeText: string, type: string, text: string): string {
            const found = root.scopedItem(hostKey, id, scopeType, scopeText, type, text);
            return found === null ? "absent" : JSON.stringify(root.windowBox(found));
        }
        function windowGeometry(hostKey: string, id: string, type: string, text: string): string {
            return root.labelledBox(hostKey, id, type, text, true);
        }
        // windowGeometry for a shown item enabled or not, so a row reaches
        // a disabled control.
        function shownWindowGeometry(hostKey: string, id: string, type: string, text: string): string {
            return root.labelledBox(hostKey, id, type, text, false);
        }
        // The keyboard's focus chain from the focused item under an
        // instance: the page, `ListPage` or `PluginPage`, owning that item
        // and each of the next STEPS items Tab reaches, or Shift+Tab for a
        // negative count, "none" for one outside both, as a list. Nothing
        // is focused by the walk.
        function focusChain(hostKey: string, id: string, steps: int): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const focused = root.descendants(item).filter(child => child.activeFocus);
            if (focused.length === 0) return "no-focus";
            const pageOf = node => {
                for (let at = node; at !== null && at !== undefined; at = at.parent) {
                    const type = root.typeName(at);
                    if (type === "ListPage" || type === "PluginPage") return type;
                }
                return "none";
            };
            let at = focused[focused.length - 1];
            const out = [pageOf(at)];
            for (let i = 0; i < Math.abs(steps) && at; i++) {
                at = at.nextItemInFocusChain(steps > 0);
                out.push(at ? pageOf(at) : "end");
            }
            return JSON.stringify(out);
        }
        // Every Menu under an instance, in tree order, as it stands: open or
        // not, its entries' texts, the checked ones, the highlighted one and
        // whether its entries scroll.
        function menus(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return JSON.stringify(root.descendants(item).filter(child => typeof child.items === "function" && child.opened !== undefined).map(menu => {
                const entries = menu.items();
                return {
                    opened: menu.opened,
                    entries: entries.map(e => e.text),
                    checked: entries.filter(e => e.checked).map(e => e.text),
                    current: menu.currentIndex >= 0 && menu.currentIndex < entries.length ? entries[menu.currentIndex].text : null,
                    overflowing: menu.scrollArea.overflowing,
                    barVisible: menu.scrollArea.bar.visible,
                    anchorType: root.typeName(menu.anchorItem)
                };
            }));
        }
        // Every shown ScrollArea under an instance, in tree order: its
        // scroll position, content height and height, and its bar's and
        // thumb's boxes in the window's coordinates.
        function scrollAreas(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return JSON.stringify(root.shownScrollAreas(item).map(area => ({
                contentY: area.contentY,
                contentHeight: area.contentHeight,
                height: area.height,
                contentWidth: area.contentWidth,
                width: area.width,
                barVisible: area.bar.visible,
                bar: root.windowBox(area.bar),
                thumb: root.windowBox(area.bar.thumb)
            })));
        }
        // Whether an item under the instance holds keyboard focus in an
        // active window, so a row types only once the compositor gave the
        // surface the keyboard.
        // PROPERTY of the first item named TYPE under an instance, in tree
        // order, as JSON: a view a Loader holds inside an overlay.
        function readDescendant(hostKey: string, id: string, type: string, property: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === type);
            if (found === undefined) return "absent";
            const json = JSON.stringify(found[property]);
            return json === undefined ? "undefined" : json;
        }
        // readDescendant over the items whose every ancestor is visible:
        // a list's own cursor rather than one in a closed flyout of the
        // same instance, whatever the cursor itself shows.
        function readShownDescendant(hostKey: string, id: string, type: string, property: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const placed = child => { for (let at = child.parent; at !== null && at !== item; at = at.parent) if (!at.visible) return false; return true; };
            const found = root.descendants(item).find(child => root.typeName(child) === type && placed(child));
            if (found === undefined) return "absent";
            const json = JSON.stringify(found[property]);
            return json === undefined ? "undefined" : json;
        }
        function activeFocusIn(hostKey: string, id: string): bool {
            const item = root.instance(hostKey, id);
            return item !== null && root.descendants(item).some(child => child.activeFocus);
        }
        // The launcher's rows as it draws them, in list order: each
        // LauncherRow delegate's kind, label and detail.
        function launcherRows(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const rows = root.descendants(item).filter(child => /^LauncherRow_QMLTYPE_/.test(String(child)) && child.index >= 0);
            rows.sort((a, b) => a.index - b.index);
            return JSON.stringify(rows.map(row => [row.kind, row.label, row.detail]));
        }
        // The launcher's edge light: the URL its shader loaded from and
        // whether the engine compiled it.
        function launcherShader(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const shader = root.descendants(item).find(child => child instanceof ShaderEffect);
            if (shader === undefined) return "no-shader";
            return JSON.stringify({ url: String(shader.fragmentShader), compiled: shader.status === ShaderEffect.Compiled, log: shader.log });
        }
        // Build a copy of a popup from FILE, a path beside the shipped file
        // so its imports and sibling types resolve as the shipped one's do,
        // as a child of the instance HOST_KEY/ID, whose item it anchors to,
        // with PROPERTIES, a JSON object, as its initial properties; a value
        // "@instance" there, at the top or one object down, is that item.
        // A list is assigned once the copy is made, since a list handed to
        // createObject stops being an array (runtime-qml.md). Kept under
        // NAME: `ok`, or the component's error.
        function popupLoad(name: string, file: string, hostKey: string, id: string, properties: string): string {
            if (name in root.popupCopies) return "loaded";
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const resolve = value => value === "@instance" ? item : value;
            const given = JSON.parse(properties);
            const initial = {};
            const lists = {};
            for (const key of Object.keys(given)) {
                const value = given[key];
                if (Array.isArray(value)) lists[key] = value;
                else if (value !== null && typeof value === "object") {
                    const inner = {};
                    for (const k of Object.keys(value)) inner[k] = resolve(value[k]);
                    initial[key] = inner;
                } else initial[key] = resolve(value);
            }
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return "error: " + component.errorString().trim().replace(/\n/g, " ");
            const made = component.createObject(item, initial);
            if (made === null) return "error: create";
            for (const key of Object.keys(lists)) made[key] = lists[key];
            const next = Object.assign({}, root.popupCopies);
            next[name] = made;
            root.popupCopies = next;
            return "ok";
        }
        // Call member VERB of copy NAME with no argument: `ok`, or `absent`.
        function popupCall(name: string, verb: string): string {
            const copy = root.popupCopies[name];
            if (copy === undefined) return "absent";
            copy[verb]();
            return "ok";
        }
        // PROPERTY of copy NAME as JSON, or `absent`.
        function popupRead(name: string, property: string): string {
            const copy = root.popupCopies[name];
            return copy === undefined ? "absent" : JSON.stringify(copy[property]);
        }
        function popupDrop(name: string): string {
            const copy = root.popupCopies[name];
            if (copy === undefined) return "absent";
            const next = Object.assign({}, root.popupCopies);
            delete next[name];
            root.popupCopies = next;
            copy.destroy();
            return "ok";
        }
        // Build a copy of ThemeRunner from FILE, a path under the shell's
        // Core directory so its imports resolve as the shipped one's do:
        // `ok`, or the component's error.
        function runnerLoad(file: string): string {
            if (root.runnerCopy !== null) return "loaded";
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return "error: " + component.errorString();
            const made = component.createObject(root);
            if (made === null) return "error: create";
            root.runnerAnswers = {};
            root.runnerCopy = made;
            return "ok";
        }
        // Call the copy's member VERB with ARG as a capability call would,
        // its answers kept by verb; the member's reply, `ok` for none.
        function runnerCall(verb: string, arg: string): string {
            return root.callRunner(verb, [arg]);
        }
        // runnerCall with OPTIONS, a JSON value, after `done`, as
        // `wallpapers(name, done, options)` takes it.
        function runnerCallWith(verb: string, arg: string, options: string): string {
            return root.callRunner(verb, [arg], JSON.parse(options));
        }
        // How many times the copy answered VERB.
        function runnerAnswered(verb: string): int {
            return verb in root.runnerAnswers ? root.runnerAnswers[verb].count : 0;
        }
        // The copy's lending record, or `absent`.
        function runnerRecord(): string { return root.runnerCopy === null ? "absent" : JSON.stringify(root.runnerCopy.record()); }
        function runnerDrop(): string {
            if (root.runnerCopy === null) return "absent";
            root.runnerCopy.destroy();
            root.runnerCopy = null;
            return "ok";
        }
    }
}
