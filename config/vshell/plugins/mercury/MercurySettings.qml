import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryOptions.js" as Opt

// The Mercury page in the settings app. Everything on it also lives behind the
// gear in the widget's own popout; both surfaces embed MercuryKeyPanel and
// render their choices from the option lists in MercuryLogic.js, so neither
// can offer a set the other does not.
//
// The API key is the one thing here that does NOT go through saveValue() —
// MercuryKeyPanel says why.
PluginSettings {
    id: root
    pluginId: "mercury"

    StyledText {
        width: parent.width
        text: I18n.tr("Mercury Settings")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.tr("Balances in the bar. Open the widget for accounts, activity and receipts.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: keyPanel.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        MercuryKeyPanel {
            id: keyPanel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingL
            anchors.rightMargin: Theme.spacingL

            // The key changes what the helper can see but touches no setting
            // the widget reads, so this stamp is what tells the bar to look
            // again. It holds a time, never a key.
            onKeyChanged: root.saveValue("keyChangedAt", Date.now())
        }
    }

    SelectionSetting {
        settingKey: "days"
        label: I18n.tr("Activity window")
        defaultValue: "30"
        options: Opt.daysOptions()
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: I18n.tr("Bar display")
        defaultValue: "full"
        options: Opt.pillModeOptions()
    }

    SelectionSetting {
        settingKey: "refreshSeconds"
        label: I18n.tr("Refresh")
        defaultValue: "300"
        options: Opt.refreshOptions()
    }
}
