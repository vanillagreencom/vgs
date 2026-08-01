import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets

// The Settings dropdown row with a responsive trigger. SettingsDropdownRow uses
// a fixed 200px control, which starves the label once the window narrows —
// Cloud Sync is a resizable standalone window, so the control gives way first.
SettingsDropdownRow {
    id: root

    dropdownWidth: Math.max(110, Math.min(200, width * 0.5))
}
