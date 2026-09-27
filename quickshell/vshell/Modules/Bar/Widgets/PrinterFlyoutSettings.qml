import QtQuick
import qs.Common
import qs.Modules.Settings
import qs.Widgets

// The printer widget's options, rendered inside its own flyout.
//
// It does NOT redefine the toggles. PrinterWidgetOptions is the single
// definition, and the settings application renders that same file; this
// supplies the small adapter it expects so the two surfaces cannot end up
// offering different switches or different defaults.
//
// The adapter is the only new part. In the settings application the options
// component is handed a BarWidgetOptions that already knows which bar section
// and row it is drawing, which is how it reads and writes. A flyout knows
// neither, so the write goes through SettingsData by widget id instead.
Item {
    id: root

    // The widget's own entry from the bar config, for reading current values.
    required property var widgetData

    // Queues and drivers are a different subject from these four switches, so
    // that surface stays where it is and this only offers the way there.
    signal openSystemSettings

    implicitHeight: column.implicitHeight
    height: implicitHeight

    QtObject {
        id: adapter

        readonly property string widgetId: "printer"

        function valueFor(name, fallback) {
            return root.widgetData && root.widgetData[name] !== undefined ? root.widgetData[name] : fallback;
        }

        function settingChanged(name, value) {
            SettingsData.setBarWidgetSetting("printer", name, value);
        }
    }

    Column {
        id: column
        width: root.width
        spacing: Theme.spacingM

        PrinterWidgetOptions {
            width: parent.width
            options: adapter
        }

        VgsButton {
            text: I18n.tr("Printers and queues…")
            variant: "secondary"
            onClicked: root.openSystemSettings()
        }
    }
}
