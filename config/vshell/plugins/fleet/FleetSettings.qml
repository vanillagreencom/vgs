import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

import "FleetLogic.js" as Logic

PluginSettings {
    id: root
    pluginId: "fleet"

    StyledText {
        width: parent.width
        text: "Fleet Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightSectionHeader
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "The remote fleet in the bar: the Daytona control VM, each lane and the running cost. Open the pill to attach to a lane or close it."
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: configColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: configColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            SelectionSetting {
                settingKey: "pillMode"
                label: "Pill label"
                description: "What the bar pill shows next to the icon"
                defaultValue: Logic.DEFAULTS.pillMode
                options: Logic.pillModeOptions()
            }

            ToggleSetting {
                settingKey: "showCost"
                label: "Show cost"
                description: "Running rates in the pill and the dropdown, and the month-to-date estimate"
                defaultValue: Logic.DEFAULTS.showCost
            }

            SliderSetting {
                settingKey: "pollSeconds"
                label: "Poll interval"
                description: "How often the fleet status is read while the pill is on a bar"
                defaultValue: Logic.DEFAULTS.pollSeconds
                minimum: 10
                maximum: 300
                unit: "s"
            }

            SliderSetting {
                settingKey: "staleHours"
                label: "Stale lane age"
                description: "A lane older than this turns the pill to the warning colour"
                defaultValue: Logic.DEFAULTS.staleHours
                minimum: 1
                maximum: 168
                unit: "h"
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Needs the fleet repository's client commands in ~/.local/bin: lane-host-daytona for the status and Close, fleet-attach for Attach, and fleet-code for Open in VSCodium. The status command reads DAYTONA_API_KEY from the environment or from ~/.fleet/env."
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
