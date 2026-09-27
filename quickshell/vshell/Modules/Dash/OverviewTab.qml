import QtQuick
import qs.Common
import qs.Modules.Dash.Overview

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    implicitWidth: SettingsData.showWeekNumber ? 736 : 700
    implicitHeight: 410

    signal switchToWeatherTab
    signal switchToMediaTab
    signal closeDash
    signal navFocusRequested

    function handleKeyEvent(event) {
        return calendarCard.handleKeyEvent(event);
    }

    Item {
        anchors.fill: parent

        ClockCard {
            x: 0
            y: 0
            width: parent.width * 0.2 - Theme.spacingM * 2
            height: 180
        }


        WeatherOverviewCard {
            x: SettingsData.weatherEnabled ? parent.width * 0.2 - Theme.spacingM : 0
            y: 0
            width: SettingsData.weatherEnabled ? parent.width * 0.3 : 0
            height: 100
            visible: SettingsData.weatherEnabled

            onClicked: root.switchToWeatherTab()
        }


        UserInfoCard {
            x: SettingsData.weatherEnabled ? parent.width * 0.5 : parent.width * 0.2 - Theme.spacingM
            y: 0
            width: SettingsData.weatherEnabled ? parent.width * 0.5 : parent.width * 0.8
            height: 100
        }


        SystemMonitorCard {
            x: 0
            y: 180 + Theme.spacingM
            width: parent.width * 0.2 - Theme.spacingM * 2
            height: 220
        }


        CalendarOverviewCard {
            id: calendarCard
            x: parent.width * 0.2 - Theme.spacingM
            y: 100 + Theme.spacingM
            width: parent.width * 0.6
            height: 300

            onCloseDash: root.closeDash()
            onNavFocusRequested: root.navFocusRequested()
        }


        MediaOverviewCard {
            x: parent.width * 0.8
            y: 100 + Theme.spacingM
            width: parent.width * 0.2
            height: 300

            onClicked: root.switchToMediaTab()
        }
    }
}
