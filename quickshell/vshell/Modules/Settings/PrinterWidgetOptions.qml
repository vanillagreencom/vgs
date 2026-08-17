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

    OptionToggle {
        text: I18n.tr("Hide unless queue or printing")
        checked: options.valueFor("hideWhenIdle", true)
        onChanged: value => options.settingChanged("hideWhenIdle", value)
    }
    OptionToggle {
        text: I18n.tr("Show jobs in dropdown")
        checked: options.valueFor("showJobs", true)
        onChanged: value => options.settingChanged("showJobs", value)
    }
    OptionToggle {
        text: I18n.tr("Show connected printer")
        checked: options.valueFor("showConnected", true)
        onChanged: value => options.settingChanged("showConnected", value)
    }
    OptionToggle {
        text: I18n.tr("Show job-count badge")
        checked: options.valueFor("showJobBadge", true)
        onChanged: value => options.settingChanged("showJobBadge", value)
    }
}
