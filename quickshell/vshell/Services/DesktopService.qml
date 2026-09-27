pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    readonly property var log: Log.scoped("DesktopService")
    property var _cache: ({})

    property bool isSystemd: false
    property bool systemdAutostartTargetActive: false
    property bool systemdAutostartTargetChecked: false
    readonly property bool autostartAvailable: root.systemdAutostartTargetChecked && (!root.isSystemd || root.systemdAutostartTargetActive)

    Component.onCompleted: initSystemCheckProcess.running = true

    Process {
        id: initSystemCheckProcess
        command: ["sh", "-c", "cat /proc/1/comm 2>/dev/null | tr -d '\\n'"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.isSystemd = (text || "").trim() === "systemd";
                if (!root.isSystemd)
                    root.systemdAutostartTargetChecked = true;
                else
                    systemdAutostartTargetCheck.running = true;
            }
        }
    }

    Process {
        id: systemdAutostartTargetCheck
        command: ["systemctl", "--user", "is-active", "xdg-desktop-autostart.target"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.systemdAutostartTargetActive = (text || "").trim() === "active";
                root.systemdAutostartTargetChecked = true;
            }
        }
    }

    function resolveIconPath(moddedAppId) {
        if (!moddedAppId)
            return "";

        if (_cache[moddedAppId] !== undefined)
            return _cache[moddedAppId];

        const result = (function () {
                const entry = DesktopEntries.heuristicLookup(moddedAppId);
                let icon = Quickshell.iconPath(entry?.icon, true);
                if (icon && icon !== "")
                    return icon;

                icon = Quickshell.iconPath(moddedAppId, true);
                if (icon && icon !== "")
                    return icon;

                const appIds = [moddedAppId.toLowerCase()];
                const lastPart = moddedAppId.split('.').pop();
                if (lastPart && lastPart !== moddedAppId) {
                    appIds.push(lastPart);
                    appIds.push(lastPart.toLowerCase());
                }

                for (const id of appIds) {
                    icon = Quickshell.iconPath(id, true);
                    if (icon && icon !== "")
                        return icon;
                }

                const strippedId = moddedAppId.replace(/-bin$/, "").toLowerCase();
                const allEntries = DesktopEntries.applications.values;
                for (let i = 0; i < allEntries.length; i++) {
                    const e = allEntries[i];
                    const eId = (e.id || "").toLowerCase();
                    const eName = (e.name || "").toLowerCase();
                    const eExec = (e.execString || "").toLowerCase();

                    if (eId.includes(strippedId) || eName.includes(strippedId) || eExec.includes(strippedId)) {
                        icon = Quickshell.iconPath(e.icon, true);
                        if (icon && icon !== "")
                            return icon;
                    }
                }

                for (const appId of appIds) {
                    let execPath = entry?.execString?.replace(/\/bin.*/, "");
                    if (!execPath)
                        continue;

                    if (execPath.startsWith("/nix/store/") || execPath.startsWith("/gnu/store/")) {
                        const basePath = execPath;
                        const sizes = ["256x256", "128x128", "64x64", "48x48", "32x32", "24x24", "16x16"];

                        let iconPath = `${basePath}/share/icons/hicolor/scalable/apps/${appId}.svg`;
                        icon = Quickshell.iconPath(iconPath, true);
                        if (icon && icon !== "")
                            return icon;

                        for (const size of sizes) {
                            iconPath = `${basePath}/share/icons/hicolor/${size}/apps/${appId}.png`;
                            icon = Quickshell.iconPath(iconPath, true);
                            if (icon && icon !== "")
                                return icon;
                        }
                    }
                }

                return "";
            })();

        _cache[moddedAppId] = result;
        return result;
    }

    // Distinctive tokens derived from a window app-id/class, used by
    // resolveEntryByClass() to match a running window to its desktop entry when
    // an exact id lookup fails (scratchpads, Chromium web-apps, profile suffixes).
    readonly property var _classResolveStop: ["com", "org", "net", "io", "app", "dev", "chrome", "chromium", "brave", "google", "www", "scratch", "scratchpad"]
    function classResolveTokens(appId) {
        const s = String(appId || "").toLowerCase();
        const out = [];
        const add = v => {
            if (v && v.length >= 3 && _classResolveStop.indexOf(v) === -1 && out.indexOf(v) === -1)
                out.push(v);
        };
        // Base class minus the scratchpad/profile suffix Chrome/Hyprland append:
        // "chrome-chatgpt.com__-Scratch" -> "chrome-chatgpt.com" (== StartupWMClass).
        const base = s.split("__")[0].replace(/[-_.](scratch|scratchpad|stash|pad)$/gi, "");
        add(base);
        const chrome = s.match(/^(?:chrome|chromium|brave|google-chrome|msedge)-(.+)$/i);
        if (chrome) {
            const host = chrome[1].split(/__|-/)[0]; // "chatgpt.com"
            add(host);
            add(host.split(".")[0]); // "chatgpt"
        }
        const parts = base.split(".");
        if (parts.length >= 2) {
            add(parts[parts.length - 1]); // "ghostty" from "com.ghostty"
            add(parts[parts.length - 2]); // "ghostty" from "com.ghostty.yazi"
        }
        return out;
    }

    // Best desktop entry for a window class, matched by StartupWMClass / id, then
    // distinctive tokens. Returns null when nothing plausible matches. Generic —
    // any window whose class doesn't exactly match its entry benefits, not only
    // scratchpads. Callers should prefer an exact heuristicLookup first and fall
    // back to this only when that yields no usable icon.
    function resolveEntryByClass(appId) {
        if (!appId)
            return null;
        const apps = DesktopEntries.applications;
        if (!apps || !apps.values)
            return null;
        const vals = apps.values;
        const tokens = classResolveTokens(appId);
        if (tokens.length === 0)
            return null;
        const base = tokens[0];
        let best = null;
        let bestScore = 0;
        for (let i = 0; i < vals.length; i++) {
            const e = vals[i];
            if (!e || !e.icon)
                continue;
            const sc = String(e.startupClass || "").toLowerCase();
            const id = String(e.id || "").toLowerCase();
            let score = 0;
            if (sc && sc === base)
                score = 100;
            else if (id === base)
                score = 90;
            else {
                for (let k = 0; k < tokens.length && score < 80; k++) {
                    if (sc && sc === tokens[k])
                        score = 80;
                    else if (id === tokens[k])
                        score = 75;
                }
                if (score === 0) {
                    for (let k = 0; k < tokens.length && score < 60; k++) {
                        if (tokens[k].length < 4)
                            continue;
                        if (sc && sc.indexOf(tokens[k]) >= 0)
                            score = 60;
                        else if (id.indexOf(tokens[k]) >= 0)
                            score = 50;
                    }
                }
            }
            if (score > bestScore) {
                bestScore = score;
                best = e;
            }
        }
        return bestScore > 0 ? best : null;
    }

    signal getDefaultAppResult(string mimeType, string desktopFileId, string callbackId)
    signal getAppsForMimeResult(string mimeType, var appIds, string callbackId)

    function _shellQuote(value) {
        return "'" + String(value || "").replace(/'/g, "'\\''") + "'";
    }

    function _desktopEntryId(entry) {
        const id = entry?.id || "";
        if (id)
            return id;
        const exec = entry?.execString || entry?.exec || "";
        return exec;
    }

    function _entrySupportsMime(entry, mimeType) {
        const mimes = entry && (entry.mimeTypes || entry.mimeType);
        if (!mimes)
            return false;
        if (Array.isArray(mimes))
            return mimes.indexOf(mimeType) >= 0;
        if (typeof mimes === "string")
            return mimes.split(";").indexOf(mimeType) >= 0;
        if (mimes.includes)
            return mimes.includes(mimeType);
        return false;
    }

    function setDefaultApp(mimeType, desktopFileId, callbackId = "") {
        setDefaultAppForMimes([mimeType], desktopFileId, callbackId);
    }

    function setDefaultAppForMimes(mimeTypes, desktopFileId, callbackId = "") {
        if (!desktopFileId.endsWith(".desktop")) {
            desktopFileId += ".desktop";
        }
        const filtered = (mimeTypes || []).filter(m => m && m.length > 0);
        if (filtered.length === 0)
            return;

        if (VGSBackendService.isConnected && VGSBackendService.methods.includes("mime.setDefaults")) {
            VGSBackendService.sendRequest("mime.setDefaults", {
                mimeTypes: filtered,
                desktopFileId: desktopFileId
            }, response => {
                if (response?.error)
                    log.warn("DesktopService.setDefaultApp backend failed:", response.error, "mimes:", filtered, "app:", desktopFileId);
            });
            return;
        }

        const cmd = "command -v xdg-mime >/dev/null 2>&1 && xdg-mime default " + _shellQuote(desktopFileId) + " " + filtered.map(_shellQuote).join(" ");
        Proc.runCommand("desktop-set-default-" + callbackId + "-" + filtered.join(","), ["sh", "-c", cmd], (output, exitCode, stderr) => {
            if (exitCode !== 0)
                log.warn("DesktopService.setDefaultApp failed:", stderr || output, "mimes:", filtered, "app:", desktopFileId);
        });
    }

    function getDefaultApp(mimeType, callbackId = "") {
        if (!mimeType) {
            root.getDefaultAppResult(mimeType, "", callbackId);
            return;
        }

        if (VGSBackendService.isConnected && VGSBackendService.methods.includes("mime.getDefault")) {
            VGSBackendService.sendRequest("mime.getDefault", {
                mimeType: mimeType
            }, response => {
                if (response?.error) {
                    log.warn("DesktopService.getDefaultApp backend failed:", response.error, "mime:", mimeType);
                    root.getDefaultAppResult(mimeType, "", callbackId);
                    return;
                }
                root.getDefaultAppResult(mimeType, response?.result?.desktopFileId || "", callbackId);
            });
            return;
        }

        const cmd = "command -v xdg-mime >/dev/null 2>&1 && xdg-mime query default " + _shellQuote(mimeType);
        Proc.runCommand("desktop-get-default-" + mimeType + "-" + callbackId, ["sh", "-c", cmd], (output, exitCode, stderr) => {
            if (exitCode !== 0) {
                log.warn("DesktopService.getDefaultApp failed:", stderr || output, "mime:", mimeType);
                root.getDefaultAppResult(mimeType, "", callbackId);
                return;
            }
            root.getDefaultAppResult(mimeType, (output || "").trim(), callbackId);
        });
    }

    function getAppsForMimeType(mimeType, callbackId = "") {
        if (!mimeType) {
            root.getAppsForMimeResult(mimeType, [], callbackId);
            return;
        }

        if (VGSBackendService.isConnected && VGSBackendService.methods.includes("mime.appsForMime")) {
            VGSBackendService.sendRequest("mime.appsForMime", {
                mimeType: mimeType
            }, response => {
                if (response?.error) {
                    log.warn("DesktopService.getAppsForMimeType backend failed:", response.error, "mime:", mimeType);
                    root.getAppsForMimeResult(mimeType, [], callbackId);
                    return;
                }
                root.getAppsForMimeResult(mimeType, response?.result?.appIds || [], callbackId);
            });
            return;
        }

        const ids = [];
        const seen = {};
        const apps = DesktopEntries.applications ? DesktopEntries.applications.values : [];
        for (let i = 0; i < apps.length; i++) {
            const entry = apps[i];
            if (!_entrySupportsMime(entry, mimeType))
                continue;
            const id = _desktopEntryId(entry);
            if (!id || seen[id])
                continue;
            seen[id] = true;
            ids.push(id);
        }

        if (ids.length > 0) {
            root.getAppsForMimeResult(mimeType, ids, callbackId);
            return;
        }

        const needle = _shellQuote(";" + mimeType + ";");
        const script = "needle=" + needle + "; command -v awk >/dev/null 2>&1 || exit 0; " +
            "for d in ${XDG_DATA_HOME:-$HOME/.local/share}/applications /usr/local/share/applications /usr/share/applications; do " +
            "[ -d \"$d\" ] || continue; " +
            "for f in \"$d\"/*.desktop; do " +
            "[ -f \"$f\" ] || continue; " +
            "mt=$(awk -F= '$1 == \"MimeType\" { print \";\" $2 }' \"$f\"); " +
            "case \"$mt\" in *\"$needle\"*) basename \"$f\" ;; esac; " +
            "done; " +
            "done";
        Proc.runCommand("desktop-apps-for-mime-" + mimeType + "-" + callbackId, ["sh", "-c", script], (output, exitCode, stderr) => {
            if (exitCode !== 0) {
                log.warn("DesktopService.getAppsForMimeType failed:", stderr || output, "mime:", mimeType);
                root.getAppsForMimeResult(mimeType, [], callbackId);
                return;
            }
            const fallbackIds = (output || "").split("\n").map(s => s.trim()).filter(s => s.length > 0);
            root.getAppsForMimeResult(mimeType, fallbackIds, callbackId);
        });
    }
}
