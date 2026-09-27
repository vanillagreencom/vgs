import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets

// Responsive dropdown row: shrink the control as the window narrows to leave room for the label.
SettingsDropdownRow {
    id: root

    dropdownWidth: Math.max(110, Math.min(200, width * 0.5))
}
