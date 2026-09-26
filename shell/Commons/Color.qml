pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Palette and per-surface colour roles. Plugins read these instead of
// literal colours so one theme file restyles every surface. Values come
// from the user's theme file when it holds them; the defaults below stand
// otherwise. The file is read the way Config reads shell.json: an absent
// file is the expected case, and every other load or parse failure, and a
// value that is not a string, is logged and leaves the last good palette.
Singleton {
    id: root

    readonly property string themePath: Paths.configDir + "/theme.json"

    readonly property var defaults: ({ foreground: "#cacccc", background: "#101315", accent: "#8fbcbb", urgent: "#a55555", muted: "#707880" })
    // The theme file's values for the keys in `defaults`, replaced whole.
    property var theme: ({})

    // Judge one theme file: every key in `defaults` it carries is a string.
    // Returns { ok, value } or { ok: false } after logging.
    function judge(label, text) {
        let raw;
        try {
            raw = JSON.parse(text);
        } catch (e) {
            console.error("theme: " + label + " does not parse: " + e.message);
            return { ok: false };
        }
        if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
            console.error("theme: " + label + " malformed: theme must be an object");
            return { ok: false };
        }
        const out = {};
        for (const key of Object.keys(defaults)) {
            if (raw[key] === undefined) continue;
            if (typeof raw[key] !== "string") {
                console.error("theme: " + label + " malformed: " + key + " must be a string, got " + JSON.stringify(raw[key]));
                return { ok: false };
            }
            out[key] = raw[key];
        }
        return { ok: true, value: out };
    }

    function role(name) {
        return theme[name] !== undefined ? theme[name] : defaults[name];
    }

    FileView {
        path: root.themePath
        watchChanges: true
        printErrors: false
        onLoaded: {
            const r = root.judge(path, text());
            if (r.ok) root.theme = r.value;
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) return;
            console.error("theme: " + path + " unreadable: " + error);
        }
        onFileChanged: reload()
    }

    readonly property color foreground: role("foreground")
    readonly property color background: role("background")
    readonly property color accent: role("accent")
    readonly property color urgent: role("urgent")
    readonly property color muted: role("muted")

    readonly property QtObject bar: QtObject {
        readonly property color background: root.background
        readonly property color text: root.foreground
        readonly property color active: root.accent
    }
}
