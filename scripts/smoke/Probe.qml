import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Core

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

    IpcHandler {
        target: "smoke"
        function buildCount(): int { return root.builds; }
        function frames(): int { return root.frames; }
        function configChanges(): int { return root.changes; }
        function configUserLoads(): int { return root.userLoads; }
        function configSettled(): bool { return Config.activeSave === null && !Config.reloading && !Config.reloadRequested; }
        function readInstance(hostKey: string, id: string, property: string): string { return root.read(hostKey, id, property); }
        function instanceGeometry(hostKey: string, id: string): string { return root.geometry(root.instance(hostKey, id)); }
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
    }
}
