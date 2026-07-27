import QtQuick
import qs.Common
import qs.Modules.ControlCenter.Widgets
import "../../../Common/DndFormat.js" as DndFormat

CompoundPill {
    id: root

    iconName: "do_not_disturb_on"
    iconColor: SessionData.doNotDisturb ? Theme.primary : Theme.surfaceText
    primaryText: I18n.tr("Do Not Disturb")
    isActive: SessionData.doNotDisturb

    secondaryText: {
        if (!SessionData.doNotDisturb)
            return I18n.tr("Off");
        if (SessionData.doNotDisturbUntil <= 0)
            return I18n.tr("On");
        return I18n.tr("Until %1").arg(DndFormat.clockTime(SessionData.doNotDisturbUntil, SettingsData.use24HourClock));
    }

    onToggled: SessionData.setDoNotDisturb(!SessionData.doNotDisturb)
}
