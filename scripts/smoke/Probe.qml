import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
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
    property int holdMarkers: 0
    property var holdMarker: null
    Component {
        id: holdMarkerComponent
        GlobalShortcut {
            appid: "smoke"
            name: "hold-marker"
            description: "Order hold shortcut observations"
            onPressed: root.holdMarkers += 1
        }
    }
    property var layerFrameSurface: null
    readonly property var layerFrameWindow: layerFrameSurface === null ? null : layerFrameSurface.contentItem.Window.window
    property int layerFrames: 0
    property bool layerFrameListening: true
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
    // The vgs.polkit prompt over a stand-in authentication flow, for the
    // polkit scene of scripts/sandbox-shots.sh: no sandbox path runs a live
    // flow (docs/architecture/lock-polkit.md § Validation). While shown it
    // is { surface, prompt, flow }, else null.
    property var polkitStandIn: null
    // Quickshell 0.3.1 can cut large IPC replies. Keep this equal to
    // harness.sh's ipc_reply_chars; docs/architecture/runtime.md names the fact.
    readonly property int replyChars: 32768
    property int nextReplyId: 1
    property var replyPages: ({})
    property var replyPageOrder: []
    readonly property var runnerContext: ({ id: "smoke-runner-copy", onDispose: () => () => {} })

    // Large replies are paged because Quickshell can close the socket
    // before a reply past its send buffer drains (runtime.md). Keep at
    // most the eight newest replies, split without breaking surrogate
    // pairs, and answer with the page id.
    function answer(text) {
        if (typeof text !== "string") return text;
        if (text.length <= root.replyChars) return text;
        const id = String(root.nextReplyId++);
        const sliceChars = root.replyChars - 16;
        const slices = [];
        let start = 0;
        while (start < text.length) {
            let end = Math.min(start + sliceChars, text.length);
            if (end < text.length) {
                const before = text.charCodeAt(end - 1);
                if (before >= 0xd800 && before <= 0xdbff) end -= 1;
            }
            slices.push(text.slice(start, end));
            start = end;
        }
        root.replyPages[id] = slices;
        root.replyPageOrder = root.replyPageOrder.concat([id]);
        while (root.replyPageOrder.length > 8) {
            const drop = root.replyPageOrder.shift();
            delete root.replyPages[drop];
        }
        return "paged=" + id;
    }

    // JSON reply helper for every probe answer that can grow.
    function json(value) {
        const text = JSON.stringify(value);
        return root.answer(text === undefined ? "undefined" : text);
    }

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
        return reply === undefined ? "ok" : root.answer(String(reply));
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

    // The stand-in flow holds the members of Quickshell's AuthFlow that
    // PolkitModel.viewOf and the prompt read, as pkexec asks for a
    // program. Its submit and cancel only count, so nothing reaches polkitd
    // or PAM, and no password is ever typed into it.
    Component {
        id: polkitStandInFlow
        QtObject {
            property string message: "Authentication is needed to run `/usr/bin/pacman' as the super user"
            property string actionId: "org.freedesktop.policykit.exec"
            property var identities: [{ displayName: "Ada Lovelace", string: "ada", isGroup: false }]
            property var selectedIdentity: identities[0]
            property bool isResponseRequired: true
            property string inputPrompt: "Password: "
            property bool responseVisible: false
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property bool failed: false
            property bool isCompleted: false
            property bool isCancelled: false
            property int submits: 0
            property int cancels: 0
            function submit(response) { submits += 1; }
            function cancelAuthenticationRequest() {
                cancels += 1;
                isCancelled = true;
            }
        }
    }

    // The overlay layer surface the summon host builds for an unanchored
    // summon (the `layer` component of shell/Hosts/SummonHost.qml), with
    // the placement and keyboard focus the core's judge gives kind overlay.
    Component {
        id: polkitStandInSurface
        PanelWindow {
            readonly property var place: PluginLogic.surfacePlacement("overlay", {}, Theme.space.md)
            anchors { top: place.anchors.top; bottom: place.anchors.bottom; left: place.anchors.left; right: place.anchors.right }
            margins { top: place.margins.top; bottom: place.margins.bottom; left: place.margins.left; right: place.margins.right }
            exclusionMode: place.exclusion === "ignore" ? ExclusionMode.Ignore : ExclusionMode.Normal
            exclusiveZone: 0
            color: "transparent"
            WlrLayershell.namespace: "vgs:overlay"
            WlrLayershell.layer: place.layer === "top" ? WlrLayer.Top : WlrLayer.Overlay
            WlrLayershell.keyboardFocus: PluginLogic.layerKeyboardFocus("overlay", false) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
        }
    }

    Connections {
        target: root.layerFrameListening ? root.layerFrameWindow : null
        function onFrameSwapped() { root.layerFrames += 1; }
    }

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

    // The first visible, enabled item named `type` whose `text`, `name`
    // for an icon, `label` for an icon button or `currentText` for a
    // Select is `text` inside the first visible item named
    // `scopeType` that draws `scopeText`, under an instance, or null: one
    // row's button among rows that each draw a button with the same text.
    function scopedItem(hostKey, id, scopeType, scopeText, type, text) {
        const item = root.instance(hostKey, id);
        if (item === null) return null;
        const draws = node => root.descendants(node).some(child => child instanceof Text && child.visible && child.text === scopeText);
        const scope = root.descendants(item).find(child => root.typeName(child) === scopeType && child.visible && draws(child));
        if (scope === undefined) return null;
        const found = root.descendants(scope).find(child => root.typeName(child) === type && root.reads(child, text) && child.visible && child.enabled);
        return found === undefined ? null : found;
    }

    // Whether an item reads `text`: its `text`, its `name` for an icon,
    // its `label` for an icon button, or its `currentText` for a Select,
    // which draws its choice and holds no text of its own.
    function reads(child, text) {
        return child.text === text || child.name === text || child.label === text || child.currentText === text;
    }

    // The window box of the first visible item named `type` under an
    // instance that reads `text` (reads), and enabled when `enabledOnly`
    // holds, or "absent".
    function labelledBox(hostKey, id, type, text, enabledOnly) {
        const item = root.instance(hostKey, id);
        if (item === null) return "absent";
        const found = root.descendants(item).find(child => root.typeName(child) === type && root.reads(child, text) && child.visible && (child.enabled || !enabledOnly));
        return found === undefined ? "absent" : root.json(root.windowBox(found));
    }

    function fieldOf(panel, id, key) {
        return descendants(panel).find(item => item.pluginId === id && item.key === key && typeof item.apply === "function") || null;
    }

    function geometry(item) {
        if (item === null) return "absent";
        const at = item.mapToGlobal(0, 0);
        return root.json([at.x, at.y, item.width, item.height]);
    }

    // An item's box in its own window's coordinates, as [x, y, w, h]: a
    // layer surface the compositor centres knows no place of its own on the
    // screen, so a row adds the layer's position from `hyprctl layers`.
    // Scrolls the nearest scrolling ancestor of `found` so it lies in view
    // and answers its window box after, or "absent" for null.
    function reveal(found) {
        if (found === null) return "absent";
        for (let at = found.parent; at !== null && at !== undefined; at = at.parent) {
            if (at.contentY === undefined || at.contentHeight === undefined || at.contentItem === undefined || at.contentHeight <= at.height) continue;
            const top = found.mapToItem(at.contentItem, 0, 0).y;
            if (top < at.contentY) at.contentY = Math.max(0, top);
            else if (top + found.height > at.contentY + at.height) at.contentY = Math.min(at.contentHeight - at.height, top + found.height - at.height);
            break;
        }
        return root.json(root.windowBox(found));
    }

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
        const json = root.json(value);
        return json === undefined ? "undefined" : json;
    }

    function invoke(hostKey, id, name, arg) {
        const item = instance(hostKey, id);
        if (item === null) return "absent";
        // A Settings step as its button hands it to the window (D061):
        // `act` {id, key}, `storeSecret` {id, key, account, secret} and
        // `clearSecret` {id, key, account}; each answers the manager.
        if (name === "act") {
            const a = JSON.parse(arg);
            return item.act(a.id, a.key);
        }
        if (name === "storeSecret") {
            const a = JSON.parse(arg);
            return item.storeSecret(a.id, a.key, a.account, a.secret);
        }
        if (name === "clearSecret") {
            const a = JSON.parse(arg);
            return item.clearSecret(a.id, a.key, a.account);
        }
        if (name === "applySetting") {
            const a = JSON.parse(arg);
            return root.answer(item.writeSetting(a.id, a.key, a.value));
        }
        if (name === "fieldChoice" || name === "chooseField") {
            const a = JSON.parse(arg);
            const field = fieldOf(item, a.id, a.key);
            if (field === null) return "absent";
            const editor = descendants(field).find(child => typeName(child) === "Select");
            if (editor === undefined) return "no-select";
            if (name === "chooseField") {
                editor.choose(a.index);
                return "chosen";
            }
            return root.json({ model: editor.model, index: editor.currentIndex, text: editor.currentText, value: field.value, enabled: editor.enabled });
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
            return root.json(windowBox(editor));
        }
        if (name === "heldFieldState") {
            if (heldField === null || heldEditor === null) return "absent";
            return root.json({ same: fieldOf(item, heldField.id, heldField.key) === heldField.field,
                focus: heldEditor.focus, activeFocus: heldEditor.activeFocus,
                text: heldEditor.text, cursor: heldEditor.cursorPosition });
        }
        if (typeof item[name] !== "function") return "no-function";
        const result = item[name](arg);
        return result === undefined ? "" : root.answer(String(result));
    }

    // A token's QML value as JSON.
    function themeValue(path) {
        let node = Theme;
        for (const key of path.split(".")) {
            if (node === undefined || node === null) return "absent";
            node = node[key];
        }
        return node === undefined ? "absent" : root.json(node);
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
        function pageChars(): int { return root.replyChars; }
        // Page replies are `<pages> <slice>` from precomputed slices. The
        // last page drops the reply.
        function page(id: string, index: int): string {
            const slices = root.replyPages[id];
            if (slices === undefined) return "absent";
            const pages = slices.length;
            if (index < 0 || index >= pages) return "refused: page=" + index + " pages=" + pages;
            const out = pages + " " + slices[index];
            if (index === pages - 1) {
                delete root.replyPages[id];
                root.replyPageOrder = root.replyPageOrder.filter(replyId => replyId !== id);
            }
            return out;
        }
        // Every top-level group of the token table that Theme does not
        // publish as a frozen object, so an empty list is the pass.
        function themeUnpublished(): string {
            return root.json(Object.keys(Tokens.TOKENS).filter(group => typeof Theme[group] !== "object" || Theme[group] === null || !Object.isFrozen(Theme[group])));
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
            return root.json(out);
        }
        // A missing LayerHost inputItems binding, planted only in the
        // sandbox instance. A redraw restores the shipped binding.
        function layerInputDrop(id: string): string {
            const entries = Layers.entries.filter(e => e.pluginId === id);
            if (entries.length !== 1) return "registrations=" + entries.length;
            for (const name of Object.keys(entries[0].screens))
                entries[0].screens[name].QsWindow.window.inputItems = [];
            return "ok";
        }
        // The box of the first visible, enabled item named `type` whose
        // `property` reads `value` in a plugin's layer copies, sorted by
        // screen, as [x, y, w, h] in its window, or "absent". A layer the
        // compositor places knows no position of its own, so a row adds the
        // layer's position from `hyprctl layers`.
        function layerItemGeometry(id: string, type: string, property: string, value: string): string {
            const found = root.layerItem(id, type, property, value);
            return found === null ? "absent" : root.json(root.windowBox(found));
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
            return root.json(out);
        }
        // The count of visible items named TYPE whose PROPERTY text
        // contains NEEDLE, in a plugin's layer copies.
        function layerItemsWith(id: string, type: string, property: string, needle: string): int {
            let total = 0;
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const screen of Object.keys(entry.screens).sort()) {
                    for (const item of root.descendants(entry.screens[screen]).filter(i => root.typeName(i) === type && i.visible))
                        if (String(item[property]).indexOf(needle) !== -1) total += 1;
                }
            return total;
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
        function grabbed(): string { return root.answer(root.grab); }
        // Every shader effect in a plugin's layer copies: [screen, its
        // fragment shader's URL, whether it compiled].
        function layerShaders(id: string): string {
            const out = [];
            for (const entry of Layers.entries.filter(e => e.pluginId === id))
                for (const screen of Object.keys(entry.screens).sort())
                    for (const item of root.descendants(entry.screens[screen]).filter(i => i instanceof ShaderEffect))
                        out.push([screen, String(item.fragmentShader), item.status === ShaderEffect.Compiled]);
            return root.json(out);
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
            return root.json(out);
        }
        function toastCloseGeometry(index: int): string { return Plugins.hosts.toast === undefined ? "absent" : root.answer(Plugins.hosts.toast.closeGeometry(index)); }
        function toastWindowGeometry(index: int): string { return Plugins.hosts.toast === undefined ? "absent" : root.answer(Plugins.hosts.toast.toastWindowGeometry(index)); }
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
            if (part === "card") return root.json(root.windowBox(dialog));
            if (part !== "title") return "refused: part=" + part + " want=card|title";
            const title = root.descendants(dialog).find(child => root.typeName(child) === "Label" && child.visible && child.text === dialog.title);
            return title === undefined ? "absent" : root.json(root.windowBox(title));
        }
        function noticeDrawn(): string {
            const dialog = Plugins.hosts.notice === undefined ? null : Plugins.hosts.notice.dialog;
            if (dialog === null) return "absent";
            // The Show command disclosure is read on its own, so a command
            // line reaches `rows` only when the body draws it.
            const disclosures = root.descendants(dialog).filter(child => root.typeName(child) === "CommandDisclosure");
            const inDisclosure = item => {
                for (let p = item.parent; p !== null; p = p.parent)
                    if (disclosures.indexOf(p) !== -1) return true;
                return false;
            };
            const labels = root.descendants(dialog).filter(child => root.typeName(child) === "Label" && child.visible && !inDisclosure(child));
            const shownDisclosure = disclosures.find(d => d.visible);
            return root.json({
                title: dialog.title,
                message: dialog.message,
                rows: labels.map(label => label.text).filter(text => text !== dialog.title && text !== dialog.message && !dialog.entries.some(entry => entry.label === text)),
                command: shownDisclosure === undefined ? null : { toggle: shownDisclosure.toggle.text, expanded: shownDisclosure.expanded, text: shownDisclosure.command },
                // The button that holds the keyboard, by its text or label.
                focused: (() => {
                    const held = root.descendants(dialog).find(child => child.activeFocus === true && ["Button", "IconButton"].includes(root.typeName(child)));
                    return held === undefined ? null : (held.text || held.label);
                })(),
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
            return root.json(names.filter(name => !seen[name]));
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
            return root.json(out);
        }
        // Scrolls the one shown ScrollArea under an instance to `y`, held
        // inside its content, so scripts/sandbox-shots.sh captures each
        // page of a scrolling panel. Answers [contentY, contentHeight,
        // height], or shown-scroll-areas=N when the target is ambiguous.
        // Scrolls the shown ScrollArea holding the first shown, enabled
        // item named `type` whose text is `text` under an instance so the
        // item sits a third of the way down its view, for a real click on
        // a control below the fold. Answers the new contentY, `absent` for
        // no such item, or `unscrolled` for one no shown area holds.
        function revealText(hostKey: string, id: string, type: string, text: string): string {
            const target = root.textItem(hostKey, id, type, text);
            if (target === null) return "absent";
            const item = root.instance(hostKey, id);
            const flick = root.shownScrollAreas(item).find(area => root.descendants(area).indexOf(target) !== -1);
            if (flick === undefined) return "unscrolled";
            const y = target.mapToItem(flick.contentItem, 0, 0).y - flick.height / 3;
            flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
            return String(flick.contentY);
        }
        function scrollTo(hostKey: string, id: string, y: int): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const areas = root.shownScrollAreas(item);
            if (areas.length !== 1) return "shown-scroll-areas=" + areas.length;
            const flick = areas[0];
            flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
            return root.json([flick.contentY, flick.contentHeight, flick.height]);
        }
        // Scrolls the nearest scrolling ancestor of the first shown item
        // named `type` that reads `text` (reads) so the whole item lies in
        // its view, as a wheel over that list would, and answers the item's
        // window box after, or "absent". A page with several scroll areas,
        // such as an editor holding a multi-line field, reveals the item in
        // the one that holds it.
        function revealItem(hostKey: string, id: string, type: string, text: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === type && root.reads(child, text) && child.visible);
            return root.reveal(found === undefined ? null : found);
        }
        // revealItem for the item scopedItem finds.
        function revealScopedItem(hostKey: string, id: string, scopeType: string, scopeText: string, type: string, text: string): string {
            return root.reveal(root.scopedItem(hostKey, id, scopeType, scopeText, type, text));
        }
        function galleryHeadings(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const drawn = root.descendants(item.examples).filter(child => /^SectionHeader_QMLTYPE_/.test(String(child)) && child.width > 0 && child.height > 0);
            return String(drawn.length);
        }
        // VoiceOrb examples and their actual shader status. A disposable
        // popup copy supplies the uncompiled control without a shipped hook.
        function galleryOrbs(hostKey: string, id: string, copyName: string): string {
            const item = copyName === "" ? root.instance(hostKey, id) : root.popupCopies[copyName];
            if (item === null || item === undefined) return "absent";
            const orbs = copyName === "" ? root.descendants(item).filter(child => root.typeName(child) === "VoiceOrb") : [item];
            const title = root.descendants(item).find(child => root.typeName(child) === "Label" && child.text === "Gallery");
            const viewport = root.shownScrollAreas(item)[0];
            return root.json(orbs.map(orb => {
                const shader = root.descendants(orb).find(child => child instanceof ShaderEffect);
                const point = orb.mapToGlobal(0, 0);
                const viewPoint = viewport === undefined ? null : orb.mapToItem(viewport, 0, 0);
                const window = orb.Window.window;
                return {
                    tone: orb.tone, active: orb.active, level: orb.level, secondaryLevel: orb.secondaryLevel,
                    width: orb.width, height: orb.height,
                    box: root.windowBox(orb),
                    ink: ThemeLogic.formatColor(Qt.color(Theme.voiceOrb.tone[orb.tone])),
                    scrollOffset: title === undefined ? null : Math.round(orb.mapToGlobal(0, 0).y - title.mapToGlobal(0, 0).y),
                    url: shader === undefined ? "" : String(shader.fragmentShader),
                    shaderLog: shader === undefined ? "no-shader" : shader.log,
                    shaderStatus: shader === undefined ? null : shader.status,
                    visible: orb.visible, shaderVisible: shader !== undefined && shader.visible,
                    windowVisible: window !== null && window.visible,
                    windowVisibility: window === null ? null : window.visibility,
                    global: [point.x, point.y],
                    viewportPosition: viewPoint === null ? null : [viewPoint.x, viewPoint.y],
                    viewport: viewport === undefined ? null : {
                        contentY: viewport.contentY, originY: viewport.originY,
                        contentHeight: viewport.contentHeight, width: viewport.width, height: viewport.height
                    },
                    compiled: shader !== undefined && shader.status === ShaderEffect.Compiled
                };
            }));
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
                return root.answer(ThemeLogic.formatColor(value));
            }
            return "no-example";
        }
        function themeWrite(path: string, value: string): string { return root.themeWrite(path, value); }
        function themeName(): string { return root.answer(Theme.name); }
        function themeRevision(): int { return Theme.revision; }
        function fontAvailable(family: string): bool { return Qt.fontFamilies().indexOf(family) !== -1; }
        function buildCount(): int { return root.builds; }
        function frames(): int { return root.frames; }
        function holdMarkerCount(): int { return root.holdMarkers; }
        function holdMarkerStart(): string {
            if (root.holdMarker !== null) return "held";
            root.holdMarkers = 0;
            root.holdMarker = holdMarkerComponent.createObject(root);
            return root.holdMarker === null ? "error: marker-create" : "ok";
        }
        function holdMarkerStop(): string {
            if (root.holdMarker === null) return "absent";
            root.holdMarker.destroy();
            root.holdMarker = null;
            return "ok";
        }
        // Observe only the selected layer's own QQuickWindow, not any bar.
        function watchLayerFrames(id: string): string {
            const entry = Layers.entries.find(e => e.pluginId === id);
            if (entry === undefined) return "absent";
            const surface = entry.screens[Object.keys(entry.screens).sort()[0]];
            if (surface === undefined) return "no-screen";
            root.layerFrameSurface = surface.QsWindow.window;
            root.layerFrames = 0;
            return root.layerFrameSurface.contentItem.Window.window === null ? "no-window" : "ok";
        }
        function layerFrames(): string {
            return root.layerFrameSurface === null ? "absent" : String(root.layerFrames);
        }
        function layerFrameListening(listen: bool): string {
            root.layerFrameListening = listen;
            return "ok";
        }
        function layerFrameVisible(show: bool): string {
            if (root.layerFrameSurface === null) return "absent";
            root.layerFrameSurface.visible = show;
            return "ok";
        }
        // A driver mutant draws in the same real layer as the fixture.
        // popupDrop owns it with the other disposable object copies.
        function layerOrbLoad(name: string, file: string): string {
            if (name in root.popupCopies) return "loaded";
            if (root.layerFrameSurface === null) return "absent";
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return "error: " + component.errorString();
            const made = component.createObject(root.layerFrameSurface.contentItem, { active: true, level: 0.8 });
            if (made === null) return "error: create";
            const next = Object.assign({}, root.popupCopies);
            next[name] = made;
            root.popupCopies = next;
            return "ok";
        }
        function dropLayerFrames(): string {
            root.layerFrameSurface = null;
            return "ok";
        }
        function startOrder(): string { return root.json(root.startOrder); }
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
        // The core's session lock, taken and released without a password,
        // for rows/lock.sh: a sandbox row never runs PAM against the real
        // account (docs/architecture/lock-polkit.md § Validation). The bare
        // lock takes the session over with no lock screen, as after a lock
        // client died, so the release can follow.
        function sessionUnlock(): string { return Capabilities.sessionLock.unlock(); }
        function sessionLockBare(): string { Capabilities.sessionLock.lockRequested = true; return "ok"; }
        // Each lock screen the lock plugin ID reports in its service's
        // `views`: its surface's size and the box, in that surface's
        // coordinates, of each descendant that carries an object name.
        function lockScreens(id: string): string {
            const service = root.instance("service", id);
            if (service === null) return "absent";
            if (!Array.isArray(service.views)) return "no-views";
            return root.json(service.views.filter(view => view !== null).map(view => {
                const parts = {};
                for (const child of root.descendants(view))
                    if (child.objectName !== "") parts[child.objectName] = root.windowBox(child);
                return { width: view.width, height: view.height, parts: parts };
            }));
        }
        // A plugin's published status values, as each of its instances reads them.
        function statusValues(id: string): string { return JSON.stringify(PluginStatus.valuesOf(id)); }
        function jarvisProcess(): string {
            const service = root.instance("service", "vgs.jarvis");
            if (service === null) return "absent";
            const process = Array.from(service.resources).find(resource => resource.processId !== undefined);
            if (process === undefined) return "missing";
            return JSON.stringify({ pid: process.processId, lifetime: service.lifetime, retries: service.retries,
                status: service.shell.status.values });
        }
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
            return root.json(items.map(child => {
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
            return root.json(root.descendants(item).filter(child => root.typeName(child) === type).map(texts));
        }
        // Every item named `type` under an instance, in tree order, as the
        // colours its visible descendants named `childType` fill with,
        // written as ThemeLogic writes a resolved colour, `#rrggbbaa`.
        function itemColours(hostKey: string, id: string, type: string, childType: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return root.json(root.descendants(item).filter(child => root.typeName(child) === type).map(found =>
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
            return root.json(root.descendants(item).filter(child => child instanceof Image).map(image =>
                [local(image.source.toString()), states[image.status], [image.width, image.height], [image.implicitWidth, image.implicitHeight], [image.sourceSize.width, image.sourceSize.height]]));
        }
        // The screen the host handed an instance, as [width, height,
        // devicePixelRatio], the size in logical pixels, or "absent", so a
        // row reads the scale the shell started on.
        function screenOf(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || !item.screen) return "absent";
            return root.json([item.screen.width, item.screen.height, item.screen.devicePixelRatio]);
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
            return label === undefined ? "absent" : root.json(label.text);
        }
        function drawnFields(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const counts = {};
            for (const row of item.plugins) counts[row.id] = 0;
            for (const field of root.descendants(item))
                if (typeof field.apply === "function" && field.pluginId !== undefined) counts[field.pluginId] += 1;
            return root.json(counts);
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
            return root.json(root.descendants(item).filter(child => root.typeName(child) === "StatusRow").map(row =>
                root.descendants(row).filter(child => child !== row && takesEdit(child)).map(child => root.typeName(child))));
        }
        // Each shown TextField of every StatusRow as [the length of its text,
        // whether it or an item inside it holds the keyboard], one list per
        // row: a row reads a Connect field's state without its secret.
        function statusRowFields(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return root.json(root.descendants(item).filter(child => root.typeName(child) === "StatusRow").map(row =>
                root.descendants(row).filter(child => root.typeName(child) === "TextField" && child.visible).map(field =>
                    [field.text.length, field.activeFocus || root.descendants(field).some(inner => inner.activeFocus === true)])));
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
            return root.answer(item.shell.doctor.offer(owner, commands.split(",")));
        }
        function doctorMissing(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.shell === null || item.shell.doctor === undefined) return "absent";
            return root.json(item.shell.doctor.missing);
        }
        // Publish a JSON value through the kept provider; its reply.
        function heldStatusSet(key: string, valueJson: string): string {
            return root.heldStatus === null ? "absent" : root.answer(root.heldStatus.set(key, JSON.parse(valueJson)));
        }
        // The first visible, enabled item named `type` under an instance
        // whose `text`, or `label` for an icon button, is `text`, as its
        // box in its window's coordinates, or "absent".
        // windowGeometry for the item scopedItem finds.
        function scopedWindowGeometry(hostKey: string, id: string, scopeType: string, scopeText: string, type: string, text: string): string {
            const found = root.scopedItem(hostKey, id, scopeType, scopeText, type, text);
            return found === null ? "absent" : root.json(root.windowBox(found));
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
            return root.json(out);
        }
        // Every Menu under an instance, in tree order, as it stands: open or
        // not, its entries' texts, the checked ones, the highlighted one and
        // whether its entries scroll.
        function menus(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            return root.json(root.descendants(item).filter(child => typeof child.items === "function" && child.opened !== undefined).map(menu => {
                const entries = menu.items();
                return {
                    opened: menu.opened,
                    entries: entries.map(e => e.text),
                    checked: entries.filter(e => e.checked).map(e => e.text),
                    current: menu.currentIndex >= 0 && menu.currentIndex < entries.length ? entries[menu.currentIndex].text : null,
                    overflowing: menu.scrollArea.overflowing,
                    barVisible: menu.scrollArea.bar.visible,
                    barHovered: menu.scrollArea.bar.hovered,
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
            return root.json(root.shownScrollAreas(item).map(area => ({
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
        // Every item named `type` under an instance, in tree order, as the
        // values of its comma-separated `properties`, a colour as its
        // #aarrggbb name, as layerItems reads a layer's.
        function itemValues(hostKey: string, id: string, type: string, properties: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const names = properties === "" ? [] : properties.split(",");
            return root.json(root.descendants(item).filter(child => root.typeName(child) === type).map(child => {
                const values = {};
                for (const name of names) values[name] = child[name] !== null && typeof child[name] === "object" && "hslHue" in child[name] ? child[name].toString() : child[name];
                return values;
            }));
        }
        function readDescendant(hostKey: string, id: string, type: string, property: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === type);
            if (found === undefined) return "absent";
            const json = root.json(found[property]);
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
            const json = root.json(found[property]);
            return json === undefined ? "undefined" : json;
        }
        // The name the theme browser's centre card draws, as JSON, or
        // `absent` while no ThemeCard is current.
        function currentThemeCardName(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === "ThemeCard" && child.current === true);
            return found === undefined ? "absent" : root.json(found.modelData.name);
        }
        function paletteStrips(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const shown = child => {
                for (let at = child; at !== null && at !== item; at = at.parent)
                    if (at.visible === false) return false;
                return true;
            };
            return root.json(root.descendants(item)
                .filter(child => root.typeName(child) === "ThemeCard")
                .map(card => {
                    const strip = root.descendants(card).find(child => child.objectName === "paletteStrip" || (root.typeName(child) === "Row" && child.parent === card && child.height === Theme.space.xxl));
                    const swatches = strip === undefined ? [] : root.descendants(strip).filter(child => child !== strip && child.visible && child.width > 0 && child.color !== undefined);
                    return [card.modelData.name, shown(card), strip !== undefined && shown(strip), swatches.length];
                }));
        }
        // The deepest item under an instance holding the active focus, as
        // [type, text], so a keyboard row types only once the field it
        // means holds the keys, or "no-focus".
        function activeFocusItem(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const focused = root.descendants(item).filter(child => child.activeFocus);
            if (focused.length === 0) return "no-focus";
            const at = focused[focused.length - 1];
            return root.json([root.typeName(at), at.text === undefined ? null : String(at.text)]);
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
            return root.json(rows.map(row => [row.kind, row.label, row.detail]));
        }
        // The launcher's edge light: the URL its shader loaded from and
        // whether the engine compiled it.
        function launcherShader(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const shader = root.descendants(item).find(child => child instanceof ShaderEffect);
            if (shader === undefined) return "no-shader";
            return root.json({ url: String(shader.fragmentShader), compiled: shader.status === ShaderEffect.Compiled, log: shader.log });
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
            if (component.status !== Component.Ready) return root.answer("error: " + component.errorString().trim().replace(/\n/g, " "));
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
            return copy === undefined ? "absent" : root.json(copy[property]);
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
        // Build a disposable OverlaySurface copy with the real layer
        // component, on its first screen. Only the copy's mask differs;
        // the fixture, pointer and receiver are the row's normal ones.
        // popupDrop owns its teardown with the other surface copies.
        function layerSurfaceLoad(name: string, file: string, id: string): string {
            if (name in root.popupCopies) return "loaded";
            const entry = Layers.entries.find(e => e.pluginId === id);
            if (entry === undefined) return "absent";
            const original = entry.screens[Object.keys(entry.screens).sort()[0]];
            if (original === undefined) return "no-screen";
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return root.answer("error: " + component.errorString().trim().replace(/\n/g, " "));
            const made = component.createObject(root, { placement: "center", inset: 0, visible: false });
            if (made === null) return "error: create";
            made.screen = original.screen;
            made.WlrLayershell.namespace = "vgs:layer-control";
            made.WlrLayershell.keyboardFocus = WlrKeyboardFocus.None;
            const content = entry.component.createObject(made.contentItem);
            if (content === null) {
                made.destroy();
                return "error: content";
            }
            content.screen = original.screen;
            content.anchors.fill = made.contentItem;
            made.inputItems = Qt.binding(() => content.inputItems);
            made.inputAll = Qt.binding(() => content.inputAll);
            const next = Object.assign({}, root.popupCopies);
            next[name] = made;
            root.popupCopies = next;
            made.visible = true;
            return "ok";
        }
        // The prompt of FILE, the sandbox tree's vgs.polkit Prompt.qml,
        // built in a stand-in of the summon host's overlay layer surface on
        // the focused screen and opened as the host opens it, over a fresh
        // stand-in flow its `shell` lends as the polkit agent's. The plugin
        // itself stays disabled, so the core builds no agent. `ok`, or a
        // keyed refusal.
        function polkitStandInOpen(file: string): string {
            if (root.polkitStandIn !== null) return "refused: stand-in=open";
            const screen = Compositor.focusedScreen();
            if (screen === null) return "refused: screen=none";
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return root.answer("error: " + component.errorString().trim().replace(/\n/g, " "));
            const flow = polkitStandInFlow.createObject(root);
            const surface = polkitStandInSurface.createObject(root, { visible: false });
            if (flow === null || surface === null) {
                if (flow !== null) flow.destroy();
                if (surface !== null) surface.destroy();
                return "error: create";
            }
            const prompt = component.createObject(surface.contentItem);
            if (prompt === null) {
                surface.destroy();
                flow.destroy();
                return "error: prompt";
            }
            surface.screen = screen;
            prompt.anchors.fill = surface.contentItem;
            // Assigned after creation, as the core assigns it: a JS object
            // handed to createObject crosses a QVariant conversion
            // (docs/architecture/runtime-qml.md).
            prompt.shell = { polkit: { agent: { flow: flow } } };
            root.polkitStandIn = { surface: surface, prompt: prompt, flow: flow };
            surface.visible = true;
            try {
                prompt.open("{}");
            } catch (e) {
                return root.answer("error: open " + e.message);
            }
            return "ok";
        }
        // The stand-in flow after a failed attempt: PAM asks again and
        // the prompt shows the failed note.
        function polkitStandInFail(): string {
            if (root.polkitStandIn === null) return "absent";
            root.polkitStandIn.flow.failed = true;
            return "ok";
        }
        // Close the prompt as the host does before it hides a surface,
        // then destroy the surface, the prompt and the flow. Answers the
        // flow's submit and cancel counts as JSON, read after the close.
        function polkitStandInDrop(): string {
            const standIn = root.polkitStandIn;
            if (standIn === null) return "absent";
            root.polkitStandIn = null;
            standIn.prompt.close();
            const counts = root.json({ submits: standIn.flow.submits, cancels: standIn.flow.cancels });
            standIn.surface.destroy();
            standIn.flow.destroy();
            return counts;
        }
        // Build a copy of ThemeRunner from FILE, a path under the shell's
        // Core directory so its imports resolve as the shipped one's do:
        // `ok`, or the component's error.
        function runnerLoad(file: string): string {
            if (root.runnerCopy !== null) return "loaded";
            const component = Qt.createComponent("file://" + file);
            if (component.status !== Component.Ready) return root.answer("error: " + component.errorString());
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
        function runnerRecord(): string { return root.runnerCopy === null ? "absent" : root.json(root.runnerCopy.record()); }
        function runnerDrop(): string {
            if (root.runnerCopy === null) return "absent";
            root.runnerCopy.destroy();
            root.runnerCopy = null;
            return "ok";
        }
    }
}
