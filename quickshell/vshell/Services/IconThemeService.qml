pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("IconThemeService")

    readonly property string managedTheme: {
        if (typeof SettingsData === "undefined")
            return "";
        const t = SettingsData.resolveIconTheme();
        return (!t || t === "System Default") ? "" : t;
    }

    // Icon name to file path for managedTheme, from `vshell icons index`. It is
    // replaced whole on each load, so every resolve() binding re-evaluates once
    // when the index lands rather than once per icon.
    property var _index: ({})

    onManagedThemeChanged: {
        _index = ({});
        _load();
    }
    Component.onCompleted: _load()

    // An app installed during the session can bring icons the loaded index lacks.
    // The current index stays in place until the reloaded one lands.
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            root._load();
        }
    }

    // Proc debounces calls that share the "iconIndex" id into one helper run.
    function _load() {
        if (!managedTheme)
            return;
        const theme = managedTheme;
        Proc.runCommand("iconIndex", [Paths.vshellCli, "icons", "index", theme], (out, code, err) => {
            if (root.managedTheme !== theme)
                return;
            if (code !== 0) {
                root.log.warn("icon index failed for", theme, "exit", code, (err || "").trim());
                return;
            }
            try {
                const index = JSON.parse(out || "");
                if (index === null || typeof index !== "object" || Array.isArray(index))
                    throw new Error("not an object");
                root._index = index;
            } catch (e) {
                root.log.warn("icon index for", theme, "is not a JSON object:", e);
            }
        });
    }

    function resolve(name) {
        const index = _index;
        if (!name || !Object.prototype.hasOwnProperty.call(index, name))
            return "";
        // Route through Quickshell's icon image provider rather than a raw
        // file:// URL: the provider renders at the device pixel ratio (crisp),
        // whereas a plain file:// source is loaded at native size and mipmapped
        // down, which visibly softened large themed icons on HiDPI (dock tiles).
        return "image://icon/" + index[name];
    }
}
