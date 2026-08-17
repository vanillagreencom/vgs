pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

QtObject {
    id: root

    function coreWidgets() {
        return [
            {
                "id": "layout",
                "text": I18n.tr("Layout"),
                "description": I18n.tr("Display and switch MangoWC layouts"),
                "icon": "view_quilt",
                "enabled": CompositorService.isMango && MangoService.available,
                "warning": !CompositorService.isMango ? I18n.tr("Requires MangoWC compositor") : (!MangoService.available ? I18n.tr("Mango service not available") : undefined)
            },
            {
                "id": "launcherButton",
                "text": I18n.tr("App Launcher"),
                "description": I18n.tr("Quick access to application launcher"),
                "icon": "apps",
                "enabled": true
            },
            {
                "id": "workspaceSwitcher",
                "text": I18n.tr("Workspace Switcher"),
                "description": I18n.tr("Shows current workspace and allows switching"),
                "icon": "view_module",
                "enabled": true
            },
            {
                "id": "focusedWindow",
                "text": I18n.tr("Focused Window"),
                "description": I18n.tr("Display currently focused application title"),
                "icon": "window",
                "enabled": true
            },
            {
                "id": "runningApps",
                "text": I18n.tr("Running Apps"),
                "description": I18n.tr("Shows all running applications with focus indication"),
                "icon": "apps",
                "enabled": true
            },
            {
                "id": "appsDock",
                "text": I18n.tr("Apps Dock"),
                "description": I18n.tr("Pinned and running apps with drag-and-drop"),
                "icon": "dock_to_bottom",
                "enabled": true
            },
            {
                "id": "clock",
                "text": I18n.tr("Clock"),
                "description": I18n.tr("Current time and date display"),
                "icon": "schedule",
                "enabled": true
            },
            {
                "id": "weather",
                "text": I18n.tr("Weather Widget"),
                "description": I18n.tr("Current weather conditions and temperature"),
                "icon": "wb_sunny",
                "enabled": true
            },
            {
                "id": "music",
                "text": I18n.tr("Media Controls"),
                "description": I18n.tr("Control currently playing media"),
                "icon": "music_note",
                "enabled": true
            },
            {
                "id": "clipboard",
                "text": I18n.tr("Clipboard Manager"),
                "description": I18n.tr("Access clipboard history"),
                "icon": "content_paste",
                "enabled": true
            },
            {
                "id": "cpuUsage",
                "text": I18n.tr("CPU Usage"),
                "description": I18n.tr("CPU usage indicator"),
                "icon": "memory",
                "enabled": DgopService.dgopAvailable,
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : undefined
            },
            {
                "id": "memUsage",
                "text": I18n.tr("Memory Usage"),
                "description": I18n.tr("Memory usage indicator"),
                "icon": "developer_board",
                "enabled": DgopService.dgopAvailable,
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : undefined
            },
            {
                "id": "diskUsage",
                "text": I18n.tr("Disk Usage"),
                "description": I18n.tr("Disk usage indicator"),
                "icon": "storage",
                "enabled": DgopService.dgopAvailable,
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : undefined
            },
            {
                "id": "cpuTemp",
                "text": I18n.tr("CPU Temperature"),
                "description": I18n.tr("CPU temperature display"),
                "icon": "device_thermostat",
                "enabled": DgopService.dgopAvailable,
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : undefined
            },
            {
                "id": "gpuTemp",
                "text": I18n.tr("GPU Temperature"),
                "description": I18n.tr("GPU temperature display"),
                "icon": "auto_awesome_mosaic",
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : I18n.tr("This widget prevents GPU power off states, which can significantly impact battery life on laptops. It is not recommended to use this on laptops with hybrid graphics."),
                "enabled": DgopService.dgopAvailable
            },
            {
                "id": "systemTray",
                "text": I18n.tr("System Tray"),
                "description": I18n.tr("System notification area icons"),
                "icon": "notifications",
                "enabled": true
            },
            {
                "id": "privacyIndicator",
                "text": I18n.tr("Privacy Indicator"),
                "description": I18n.tr("Shows when microphone, camera, or screen sharing is active"),
                "icon": "privacy_tip",
                "enabled": true
            },
            {
                "id": "controlCenterButton",
                "text": I18n.tr("Control Center"),
                "description": I18n.tr("Access to system controls and settings"),
                "icon": "settings",
                "enabled": true
            },
            {
                "id": "notificationButton",
                "text": I18n.tr("Notification Center"),
                "description": I18n.tr("Access to notifications and do not disturb"),
                "icon": "notifications",
                "enabled": true
            },
            {
                "id": "battery",
                "text": I18n.tr("Battery"),
                "description": I18n.tr("Battery level and power management"),
                "icon": "battery_std",
                "enabled": true
            },
            {
                "id": "vpn",
                "text": I18n.tr("VPN"),
                "description": I18n.tr("VPN status and quick connect"),
                "icon": "vpn_lock",
                "enabled": true
            },
            {
                "id": "idleInhibitor",
                "text": I18n.tr("Idle Inhibitor"),
                "description": I18n.tr("Prevent screen timeout"),
                "icon": "motion_sensor_active",
                "enabled": true
            },
            {
                "id": "capsLockIndicator",
                "text": I18n.tr("Caps Lock Indicator"),
                "description": I18n.tr("Shows when caps lock is active"),
                "icon": "shift_lock",
                "enabled": true
            },
            {
                "id": "spacer",
                "text": I18n.tr("Spacer"),
                "description": I18n.tr("Customizable empty space"),
                "icon": "more_horiz",
                "enabled": true
            },
            {
                "id": "separator",
                "text": I18n.tr("Separator"),
                "description": I18n.tr("Visual divider between widgets"),
                "icon": "remove",
                "enabled": true
            },
            {
                "id": "network_speed_monitor",
                "text": I18n.tr("Network Speed Monitor"),
                "description": I18n.tr("Network download and upload speed display"),
                "icon": "network_check",
                "warning": !DgopService.dgopAvailable ? I18n.tr("Requires 'dgop' tool") : undefined,
                "enabled": DgopService.dgopAvailable
            },
            {
                "id": "keyboard_layout_name",
                "text": I18n.tr("Keyboard Layout Name"),
                "description": I18n.tr("Displays the active keyboard layout and allows switching"),
                "icon": "keyboard"
            },
            {
                "id": "notepadButton",
                "text": I18n.tr("Notepad"),
                "description": I18n.tr("Quick access to notepad"),
                "icon": "assignment",
                "enabled": true
            },
            {
                "id": "colorPicker",
                "text": I18n.tr("Color Picker"),
                "description": I18n.tr("Quick access to color picker"),
                "icon": "palette",
                "enabled": true
            },
            {
                "id": "powerMenuButton",
                "text": I18n.tr("Power"),
                "description": I18n.tr("Display the power system menu"),
                "icon": "power_settings_new",
                "enabled": true
            },
            {
                "id": "printer",
                "text": I18n.tr("Printer"),
                "description": I18n.tr("Print queue and printer status"),
                "icon": "print",
                "enabled": true
            }
        ];
    }
}
