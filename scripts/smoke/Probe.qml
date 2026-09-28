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
    property var heldField: null
    property var heldEditor: null

    Connections {
        target: Plugins
        function onBuiltChanged() {
            const rows = [];
            for (const key of Object.keys(Plugins.built))
                for (const row of Plugins.built[key])
                    if (row.origin === "core") rows.push(row);
            for (const row of rows)
                if (root.previousRows.indexOf(row) === -1) root.builds += 1;
            root.previousRows = rows;
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
            function onFrameSwapped() { root.frames += 1; }
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

    function fieldOf(panel, id, key) {
        return descendants(panel).find(item => item.pluginId === id && item.key === key && typeof item.apply === "function") || null;
    }

    function geometry(item) {
        if (item === null) return "absent";
        const at = item.mapToGlobal(0, 0);
        return JSON.stringify([at.x, at.y, item.width, item.height]);
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
            return geometry(editor);
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
        // The components of qs.Ui, read from its qmldir, that the gallery
        // draws no instance of; an empty list is the pass. A QML-defined
        // type prints as `<Name>_QMLTYPE_<n>(...)`.
        function galleryMissing(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null || item.examples === undefined) return "absent";
            const names = [];
            for (const line of uiModule.text().split("\n")) {
                const m = /^(\w+) 1\.0 \S+$/.exec(line);
                if (m !== null && m[1] !== "BarWidget") names.push(m[1]);
            }
            if (names.length < 20) return "qmldir-read-broken=" + names.length;
            const seen = {};
            for (const child of root.descendants(item.examples)) {
                const m = /^(\w+)_QMLTYPE_/.exec(String(child));
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
        // list and a Label's role. A row measures alignment from it, so the
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
                    role: child.role
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
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const found = root.descendants(item).find(child => root.typeName(child) === type && child.text === text && child.visible && child.enabled);
            return root.geometry(found === undefined ? null : found);
        }
        // Every Image under an instance, in tree order, as the local path it
        // draws, without a query ("" for none), its status (`null`, `ready`, `loading` or
        // `error`), its box's size and the size it decoded the file to, so
        // a row reads what a background draws.
        function images(hostKey: string, id: string): string {
            const item = root.instance(hostKey, id);
            if (item === null) return "absent";
            const states = { [Image.Null]: "null", [Image.Ready]: "ready", [Image.Loading]: "loading", [Image.Error]: "error" };
            const local = url => url === "" ? "" : decodeURIComponent(url.replace(/^file:\/\//, "").replace(/\?.*$/, ""));
            return JSON.stringify(root.descendants(item).filter(child => child instanceof Image).map(image =>
                [local(image.source.toString()), states[image.status], [image.width, image.height], [image.implicitWidth, image.implicitHeight]]));
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
        // Whether an item under the instance holds keyboard focus in an
        // active window, so a row types only once the compositor gave the
        // surface the keyboard.
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
    }
}
