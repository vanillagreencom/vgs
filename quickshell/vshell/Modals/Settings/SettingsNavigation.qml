pragma Singleton
import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    function _withTabIndexes(cats) {
        return cats.map(cat => {
            const c = Object.assign({}, cat);
            if (c.children)
                c.children = c.children.map(ch => Object.assign({}, ch, {
                        "tabIndex": SettingsRegistry.tabIndexFor(ch.id)
                    }));
            else if (!c.separator)
                c.tabIndex = SettingsRegistry.tabIndexFor(c.id);
            return c;
        });
    }

    readonly property var categories: _withTabIndexes([
        {
            "id": "displays",
            "text": I18n.tr("Displays"),
            "icon": "monitor",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "display_config",
                    "text": I18n.tr("Display Settings"),
                    "icon": "display_settings"
                },
                {
                    "id": "display_gamma",
                    "text": I18n.tr("Night Mode"),
                    "icon": "brightness_6"
                },
                {
                    "id": "display_widgets",
                    "text": I18n.tr("Widgets", "settings_displays"),
                    "icon": "widgets"
                }
            ]
        },
        {
            "id": "personalization",
            "text": I18n.tr("Personalization"),
            "icon": "palette",
            "children": [
                {
                    "id": "theme",
                    "text": I18n.tr("Themes"),
                    "icon": "format_paint"
                },
                {
                    "id": "wallpaper",
                    "text": I18n.tr("Wallpaper"),
                    "icon": "wallpaper",
                    "treeChild": true
                },
                {
                    "id": "colors",
                    "text": I18n.tr("Colors"),
                    "icon": "palette",
                    "treeChild": true
                },
                {
                    "id": "icons",
                    "text": I18n.tr("Icons"),
                    "icon": "interests",
                    "treeChild": true
                },
                {
                    "id": "screensaver",
                    "text": I18n.tr("Screensaver"),
                    "icon": "screenshot_monitor",
                    "treeChild": true
                },
                {
                    "id": "interface",
                    "text": I18n.tr("Interface"),
                    "icon": "web_asset"
                },
                {
                    "id": "typography",
                    "text": I18n.tr("Typography"),
                    "icon": "text_fields"
                },
                {
                    "id": "motion",
                    "text": I18n.tr("Motion"),
                    "icon": "auto_awesome_motion"
                },
                {
                    "id": "time_weather",
                    "text": I18n.tr("Time & Weather"),
                    "icon": "schedule"
                },
                {
                    "id": "sounds",
                    "text": I18n.tr("Sounds"),
                    "icon": "volume_up",
                    "soundsOnly": true
                }
            ]
        },
        {
            "id": "dock_launcher",
            "text": I18n.tr("Dock & Launcher"),
            "icon": "shelf_auto_hide",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "dock",
                    "text": I18n.tr("Dock"),
                    "icon": "dock_to_bottom"
                },
                {
                    "id": "launcher",
                    "text": I18n.tr("Launcher"),
                    "icon": "grid_view"
                }
            ]
        },
        {
            "id": "bar",
            "text": I18n.tr("Bar"),
            "icon": "toolbar",
            "children": [
                {
                    "id": "bar_appearance",
                    "text": I18n.tr("Appearance"),
                    "icon": "palette"
                },
                {
                    "id": "bar_settings",
                    "text": I18n.tr("Behavior"),
                    "icon": "tune"
                },
                {
                    "id": "bar_widgets",
                    "text": I18n.tr("Widgets"),
                    "icon": "widgets"
                }
            ]
        },
        {
            "id": "workspaces_widgets",
            "text": I18n.tr("Widgets & Notifications"),
            "icon": "dashboard",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "vgs_dash",
                    "text": I18n.tr("Dash"),
                    "icon": "space_dashboard"
                },
                {
                    "id": "media_player",
                    "text": I18n.tr("Media Player"),
                    "icon": "music_note"
                },
                {
                    "id": "notifications",
                    "text": I18n.tr("Notifications"),
                    "icon": "notifications"
                },
                {
                    "id": "osd",
                    "text": I18n.tr("On-screen Displays"),
                    "icon": "tune"
                },
                {
                    "id": "desktop_widgets",
                    "text": I18n.tr("Desktop Widgets"),
                    "icon": "widgets"
                }
            ]
        },
        {
            "id": "windows",
            "text": I18n.tr("Windows & Workspaces"),
            "icon": "select_window",
            "children": [
                {
                    "id": "workspaces",
                    "text": I18n.tr("Workspaces"),
                    "icon": "view_module"
                },
                {
                    "id": "compositor_layout",
                    "text": (CompositorService.isNiri ? "Niri" : (CompositorService.isHyprland ? "Hyprland" : "MangoWC")) + " " + I18n.tr("Layout"),
                    "icon": "layers",
                    "layoutCapable": true
                },
                {
                    "id": "window_rules",
                    "text": I18n.tr("Window Rules"),
                    "icon": "rule",
                    "windowRulesCapable": true
                },
                {
                    "id": "scratchpads",
                    "text": I18n.tr("Scratchpads"),
                    "icon": "picture_in_picture"
                }
            ]
        },
        {
            "id": "keybinds",
            "text": I18n.tr("Keyboard Shortcuts"),
            "icon": "keyboard",
            "shortcutsOnly": true
        },
        {
            "id": "network",
            "text": I18n.tr("Network"),
            "icon": "wifi",
            "vgsOnly": true,
            "children": [
                {
                    "id": "network_status",
                    "text": I18n.tr("Status"),
                    "icon": "lan"
                },
                {
                    "id": "network_ethernet",
                    "text": I18n.tr("Ethernet"),
                    "icon": "settings_ethernet"
                },
                {
                    "id": "network_wifi",
                    "text": I18n.tr("Wi-Fi"),
                    "icon": "wifi"
                },
                {
                    "id": "network_vpn",
                    "text": I18n.tr("VPN"),
                    "icon": "vpn_key"
                }
            ]
        },
        {
            "id": "applications",
            "text": I18n.tr("Applications"),
            "icon": "apps",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "default_apps",
                    "text": I18n.tr("Default Apps"),
                    "icon": "star"
                },
                {
                    "id": "developer",
                    "text": I18n.tr("Developer"),
                    "icon": "code"
                },
                {
                    "id": "running_apps",
                    "text": I18n.tr("Running Apps"),
                    "icon": "app_registration",
                    "hyprlandNiriOnly": true
                },
                {
                    "id": "autostart",
                    "text": I18n.tr("Autostart"),
                    "icon": "line_start",
                    "autostartOnly": true
                }
            ]
        },
        {
            "id": "system",
            "text": I18n.tr("System"),
            "icon": "memory",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "audio",
                    "text": I18n.tr("Audio"),
                    "icon": "headphones"
                },
                {
                    "id": "locale",
                    "text": I18n.tr("Locale"),
                    "icon": "language"
                },
                {
                    "id": "clipboard",
                    "text": I18n.tr("Clipboard"),
                    "icon": "content_paste",
                    "clipboardOnly": true
                },
                {
                    "id": "printers",
                    "text": I18n.tr("Printers"),
                    "icon": "print",
                    "cupsOnly": true
                },
                {
                    "id": "multiplexers",
                    "text": I18n.tr("Multiplexers"),
                    "icon": "terminal"
                },
                {
                    "id": "users",
                    "text": I18n.tr("Users"),
                    "icon": "manage_accounts"
                }
            ]
        },
        {
            "id": "power_security",
            "text": I18n.tr("Power & Security"),
            "icon": "security",
            "collapsedByDefault": true,
            "children": [
                {
                    "id": "battery",
                    "text": I18n.tr("Battery"),
                    "icon": "battery_charging_full"
                },
                {
                    "id": "lock_screen",
                    "text": I18n.tr("Lock Screen"),
                    "icon": "lock"
                },
                {
                    "id": "greeter",
                    "text": I18n.tr("Greeter"),
                    "icon": "login"
                },
                {
                    "id": "power_sleep",
                    "text": I18n.tr("Power & Sleep"),
                    "icon": "power_settings_new"
                }
            ]
        },
        {
            "id": "plugins",
            "text": I18n.tr("Plugins"),
            "icon": "extension"
        },
        {
            "id": "separator",
            "separator": true
        },
        {
            "id": "about",
            "text": I18n.tr("About"),
            "icon": "info"
        }
    ])

    function isItemVisible(item) {
        if (item.vgsOnly && NetworkService.usingLegacy)
            return false;
        if (item.cupsOnly && !CupsService.cupsAvailable)
            return false;
        if (item.shortcutsOnly && !KeybindsService.available)
            return false;
        if (item.soundsOnly && !AudioService.soundsAvailable)
            return false;
        if (item.hyprlandNiriOnly && !CompositorService.isNiri && !CompositorService.isHyprland)
            return false;
        if (item.windowRulesCapable && !CompositorService.isNiri && !CompositorService.isHyprland && !CompositorService.isMango)
            return false;
        if (item.layoutCapable && !CompositorService.isNiri && !CompositorService.isHyprland && !CompositorService.isMango)
            return false;
        if (item.niriOnly && !CompositorService.isNiri)
            return false;
        if (item.clipboardOnly && (!VGSBackendService.isConnected || !VGSBackendService.capabilities.includes("clipboard") || !VGSBackendService.methods.includes("clipboard.getConfig")))
            return false;
        if (item.autostartOnly && !DesktopService.autostartAvailable)
            return false;
        return true;
    }

    function hasVisibleChildren(category) {
        if (!category.children)
            return false;
        return category.children.some(child => isItemVisible(child));
    }

    function isCategoryVisible(category) {
        if (category.separator)
            return true;
        if (!isItemVisible(category))
            return false;
        if (category.children && !hasVisibleChildren(category))
            return false;
        return true;
    }

    function groupFor(tabIndex) {
        return categories.find(category => category.children?.some(item => item.tabIndex === tabIndex)) || null;
    }

    function tabsFor(tabIndex) {
        const group = groupFor(tabIndex);
        return group && isItemVisible(group) ? group.children.filter(item => isItemVisible(item)) : [];
    }

    function pageIds() {
        const ids = [];
        for (const category of categories) {
            if (category.separator || !isCategoryVisible(category))
                continue;
            for (const item of category.children || [category]) {
                if (isItemVisible(item))
                    ids.push(item.id);
            }
        }
        return ids;
    }
}
