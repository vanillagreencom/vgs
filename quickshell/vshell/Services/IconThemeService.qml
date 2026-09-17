pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("IconThemeService")
    readonly property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation))

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
    Component.onCompleted: {
        _load();
        Qt.callLater(checkIconThemeDrift);
    }

    // An app installed during the session can bring icons the loaded index lacks.
    // The current index stays in place until the reloaded one lands.
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            root._load();
        }
    }

    // Per-mode icon themes follow a light or dark switch the user makes.
    Connections {
        target: SessionData
        function onIsLightModeChanged() {
            if (!SessionData.isSwitchingMode)
                return;
            if (!SettingsData.iconThemePerMode)
                return;
            if (SettingsData.iconThemeLight === SettingsData.iconThemeDark)
                return;
            root.applyStoredIconTheme();
        }
    }

    // SettingsData stores the icon theme settings; applying them to the toolkits happens here.
    Connections {
        target: SettingsData
        function onIconThemeSettingChanged(key) {
            iconThemeApplyTimer.restart();
        }
    }

    Timer {
        id: iconThemeApplyTimer
        interval: 100
        repeat: false
        onTriggered: root.applyStoredIconTheme()
    }

    function applyStoredIconTheme() {
        updateGtkIconTheme();
        updateQtIconTheme();
        updateCosmicIconTheme();
    }

    function checkIconThemeDrift() {
        if (SettingsData.isGreeterMode)
            return;
        if (SettingsData.resolveIconTheme() === "System Default")
            return;
        if (!SettingsData.lastAppliedIconTheme)
            return;
        const script = `if command -v gsettings >/dev/null 2>&1; then
        gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | sed "s/'//g"
        elif command -v dconf >/dev/null 2>&1; then
        dconf read /org/gnome/desktop/interface/icon-theme 2>/dev/null | sed "s/'//g"
        fi`;

        Proc.runCommand("iconThemeDriftCheck", ["sh", "-c", script], (output, exitCode) => {
            const platform = (output || "").trim();
            if (!platform)
                return;
            if (platform === SettingsData.lastAppliedIconTheme || platform === SettingsData.iconThemeDark || platform === SettingsData.iconThemeLight)
                return;
            SettingsData.setIconThemeUnmanaged();
            ToastService.showWarning(I18n.tr("Icon theme changed outside VGS; switched to System Default", "shown when an external tool overrides the icon theme VGS applied"));
        });
    }

    function updateCosmicIconTheme() {
        if (!SettingsData.cosmicIntegrationAvailable())
            return;
        const cosmicThemeName = SettingsData.resolveIconTheme();
        if (!cosmicThemeName || cosmicThemeName === "System Default") {
            const detectScript = `if command -v gsettings >/dev/null 2>&1; then
            gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | sed "s/'//g"
            elif command -v dconf >/dev/null 2>&1; then
            dconf read /org/gnome/desktop/interface/icon-theme 2>/dev/null | sed "s/'//g"
            fi`;

            Proc.runCommand("detectCosmicIconTheme", ["sh", "-c", detectScript], (output, exitCode) => {
                if (exitCode !== 0)
                    return;
                const detected = (output || "").trim();
                if (!detected || detected === "System Default")
                    return;
                const detectedEscaped = detected.replace(/'/g, "'\\''");
                const writeScript = `mkdir -p ${configDir}/cosmic/com.system76.CosmicTk/v1
                printf '"%s"\\n' '${detectedEscaped}' > ${configDir}/cosmic/com.system76.CosmicTk/v1/icon_theme 2>/dev/null || true`;
                Quickshell.execDetached(["sh", "-lc", writeScript]);
            });
            return;
        }

        const cosmicThemeNameEscaped = cosmicThemeName.replace(/'/g, "'\\''");
        const script = `mkdir -p ${configDir}/cosmic/com.system76.CosmicTk/v1
        printf '"%s"\\n' '${cosmicThemeNameEscaped}' > ${configDir}/cosmic/com.system76.CosmicTk/v1/icon_theme 2>/dev/null || true`;
        Quickshell.execDetached(["sh", "-lc", script]);
    }

    function updateGtkIconTheme() {
        const gtkThemeName = SettingsData.resolveIconTheme();
        if (gtkThemeName === "System Default" || gtkThemeName === "")
            return;
        if (SettingsData.lastAppliedIconTheme !== gtkThemeName)
            SettingsData.set("lastAppliedIconTheme", gtkThemeName);
        if (typeof VGSBackendService !== "undefined" && VGSBackendService.methods.includes("freedesktop.settings.setIconTheme") && typeof PortalService !== "undefined") {
            PortalService.setSystemIconTheme(gtkThemeName);
        }

        const configScript = `mkdir -p ${configDir}/gtk-3.0 ${configDir}/gtk-4.0

        for config_dir in ${configDir}/gtk-3.0 ${configDir}/gtk-4.0; do
        settings_file="$config_dir/settings.ini"
        [ -f "$settings_file" ] && [ ! -w "$settings_file" ] && continue
        if [ -f "$settings_file" ]; then
        if grep -q "^gtk-icon-theme-name=" "$settings_file"; then
        sed -i 's/^gtk-icon-theme-name=.*/gtk-icon-theme-name=${gtkThemeName}/' "$settings_file"
        else
        if grep -q "\\[Settings\\]" "$settings_file"; then
        sed -i '/\\[Settings\\]/a gtk-icon-theme-name=${gtkThemeName}' "$settings_file"
        else
        echo -e '\\n[Settings]\\ngtk-icon-theme-name=${gtkThemeName}' >> "$settings_file"
        fi
        fi
        else
        echo -e '[Settings]\\ngtk-icon-theme-name=${gtkThemeName}' > "$settings_file"
        fi
        done

        if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface icon-theme '${gtkThemeName}' 2>/dev/null || true
        elif command -v dconf >/dev/null 2>&1; then
        dconf write /org/gnome/desktop/interface/icon-theme "'${gtkThemeName}'" 2>/dev/null || true
        fi

        pkill -HUP -f 'gtk' 2>/dev/null || true`;

        Quickshell.execDetached(["sh", "-lc", configScript]);
    }

    function updateQtIconTheme() {
        const resolved = SettingsData.resolveIconTheme();
        const qtThemeName = (resolved === "System Default") ? "" : resolved;
        if (!qtThemeName)
            return;
        const qtThemeNameEscaped = qtThemeName.replace(/'/g, "'\\''");

        const script = `mkdir -p ${configDir}/qt5ct ${configDir}/qt6ct ${configDir}/environment.d 2>/dev/null || true
        update_qt_icon_theme() {
        local config_file="$1"
        local theme_name="$2"
        if [ -f "$config_file" ]; then
        if grep -q "^\\[Appearance\\]" "$config_file"; then
        if grep -q "^icon_theme=" "$config_file"; then
        sed -i "s/^icon_theme=.*/icon_theme=$theme_name/" "$config_file"
        else
        sed -i "/^\\[Appearance\\]/a icon_theme=$theme_name" "$config_file"
        fi
        else
        printf "\\n[Appearance]\\nicon_theme=%s\\n" "$theme_name" >> "$config_file"
        fi
        else
        printf "[Appearance]\\nicon_theme=%s\\n" "$theme_name" > "$config_file"
        fi
        }
        update_qt_icon_theme ${configDir}/qt5ct/qt5ct.conf '${qtThemeNameEscaped}'
        update_qt_icon_theme ${configDir}/qt6ct/qt6ct.conf '${qtThemeNameEscaped}'`;

        Quickshell.execDetached(["sh", "-lc", script]);
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
        return Paths.iconProviderUrl(index[name]);
    }
}
