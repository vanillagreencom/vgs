pragma Singleton

import QtQuick
import Quickshell

// Single source of truth for settings tabs: which QML file each tab id loads
// and the tab index it occupies. Sidebar structure, content loaders, IPC name
// resolution, and search navigation all key off these ids.
//
// tabIndex values are historical and persisted (session state, IPC callers);
// never renumber them. Gaps (28, 33) are retired indexes.
Singleton {
    id: root

    // needsModal: tab exposes a `parentModal` property to set.
    // keepLoaded: heavy tab stays alive after first load instead of reloading
    //             on every visit (gets `pageActive` bound when it declares it).
    // async: load asynchronously and show a spinner while loading.
    readonly property var tabs: [
        { id: "wallpaper", tabIndex: 0, source: "WallpaperTab.qml", needsModal: true },
        { id: "time_weather", tabIndex: 1, source: "TimeWeatherTab.qml" },
        { id: "keybinds", tabIndex: 2, source: "KeybindsTab.qml", needsModal: true, keybindSearch: true },
        { id: "bar_settings", tabIndex: 3, source: "BarTab.qml", needsModal: true },
        { id: "workspaces", tabIndex: 4, source: "WorkspacesTab.qml" },
        { id: "dock", tabIndex: 5, source: "DockTab.qml", needsModal: true },
        { id: "bar_appearance", tabIndex: 6, source: "BarAppearanceTab.qml", needsModal: true },
        { id: "network_status", tabIndex: 7, source: "NetworkStatusTab.qml" },
        { id: "printers", tabIndex: 8, source: "PrinterTab.qml" },
        { id: "launcher", tabIndex: 9, source: "LauncherTab.qml", needsModal: true },
        { id: "theme", tabIndex: 10, source: "ThemesSettingsTab.qml", needsModal: true },
        { id: "lock_screen", tabIndex: 11, source: "LockScreenTab.qml" },
        { id: "plugins", tabIndex: 12, source: "PluginsTab.qml", needsModal: true },
        { id: "about", tabIndex: 13, source: "AboutTab.qml" },
        { id: "typography", tabIndex: 14, source: "TypographyTab.qml" },
        { id: "sounds", tabIndex: 15, source: "SoundsTab.qml" },
        { id: "media_player", tabIndex: 16, source: "MediaPlayerTab.qml", needsModal: true },
        { id: "notifications", tabIndex: 17, source: "NotificationsTab.qml" },
        { id: "osd", tabIndex: 18, source: "OSDTab.qml" },
        { id: "running_apps", tabIndex: 19, source: "RunningAppsTab.qml" },
        // tabIndex 20 retired with the legacy system updater UI.
        { id: "power_sleep", tabIndex: 21, source: "PowerSleepTab.qml" },
        { id: "bar_widgets", tabIndex: 22, source: "WidgetsTab.qml", needsModal: true, keepLoaded: true, async: true },
        { id: "clipboard", tabIndex: 23, source: "ClipboardTab.qml" },
        { id: "display_config", tabIndex: 24, source: "DisplayConfigTab.qml" },
        { id: "display_gamma", tabIndex: 25, source: "GammaControlTab.qml" },
        { id: "display_widgets", tabIndex: 26, source: "DisplayWidgetsTab.qml" },
        { id: "desktop_widgets", tabIndex: 27, source: "DesktopWidgetsTab.qml", needsModal: true },
        { id: "audio", tabIndex: 29, source: "AudioTab.qml" },
        { id: "locale", tabIndex: 30, source: "LocaleTab.qml" },
        { id: "greeter", tabIndex: 31, source: "GreeterTab.qml" },
        { id: "multiplexers", tabIndex: 32, source: "MuxTab.qml" },
        { id: "default_apps", tabIndex: 34, source: "DefaultAppsTab.qml" },
        { id: "users", tabIndex: 35, source: "UsersTab.qml" },
        { id: "autostart", tabIndex: 36, source: "AutoStartTab.qml", needsModal: true },
        { id: "compositor_layout", tabIndex: 37, source: "CompositorLayoutTab.qml" },
        { id: "window_rules", tabIndex: 38, source: "WindowRulesTab.qml", keepLoaded: true, async: true },
        { id: "network_ethernet", tabIndex: 39, source: "NetworkEthernetTab.qml" },
        { id: "network_wifi", tabIndex: 40, source: "NetworkWifiTab.qml" },
        { id: "network_vpn", tabIndex: 41, source: "NetworkVpnTab.qml" },
        { id: "battery", tabIndex: 42, source: "BatteryTab.qml" },
        { id: "vgs_dash", tabIndex: 43, source: "DashTab.qml" },
        { id: "motion", tabIndex: 44, source: "MotionTab.qml" },
        { id: "colors", tabIndex: 45, source: "ColorsTab.qml", needsModal: true },
        { id: "interface", tabIndex: 46, source: "InterfaceTab.qml", needsModal: true },
        { id: "icons", tabIndex: 47, source: "IconsTab.qml", needsModal: true },
        { id: "screensaver", tabIndex: 48, source: "ScreensaverTab.qml", needsModal: true },
    ]

    function tabIndexFor(id) {
        for (var i = 0; i < tabs.length; i++) {
            if (tabs[i].id === id)
                return tabs[i].tabIndex;
        }
        return -1;
    }
}
