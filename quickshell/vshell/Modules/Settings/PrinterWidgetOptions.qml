pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    required property var options

    width: parent ? parent.width : 0
    spacing: Theme.spacingS
    visible: options.widgetId === "printer"

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Hide unless queue or printing")
        checked: options.valueFor("hideWhenIdle", true)
        onToggled: value => options.settingChanged("hideWhenIdle", value)
    }
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Show jobs in dropdown")
        checked: options.valueFor("showJobs", true)
        onToggled: value => options.settingChanged("showJobs", value)
    }
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Show connected printer")
        checked: options.valueFor("showConnected", true)
        onToggled: value => options.settingChanged("showConnected", value)
    }
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Show job-count badge")
        checked: options.valueFor("showJobBadge", true)
        onToggled: value => options.settingChanged("showJobBadge", value)
    }
}
