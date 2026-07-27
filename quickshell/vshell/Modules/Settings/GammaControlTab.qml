import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    function formatGammaTime(isoString) {
        if (!isoString)
            return "";
        try {
            const date = new Date(isoString);
            if (isNaN(date.getTime()))
                return "";
            return date.toLocaleTimeString(Qt.locale(), "HH:mm");
        } catch (e) {
            return "";
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS

            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                title: I18n.tr("Color Temperature")
                iconName: "brightness_6"
                width: parent.width

                VgsToggle {
                    id: nightModeToggle

                    width: parent.width
                    text: I18n.tr("Night Mode")
                    description: DisplayService.gammaControlAvailable ? I18n.tr("Apply a warmer color temperature to reduce eye strain") : I18n.tr("Gamma control is not available on this system")
                    checked: DisplayService.nightModeEnabled
                    enabled: DisplayService.gammaControlAvailable
                    onToggled: checked => {
                        DisplayService.toggleNightMode();
                    }

                    Connections {
                        function onNightModeEnabledChanged() {
                            nightModeToggle.checked = DisplayService.nightModeEnabled;
                        }

                        target: DisplayService
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: DisplayService.gammaControlAvailable

                    SettingsSliderRow {
                        id: nightTempSlider
                        settingKey: "nightModeTemperature"
                        tags: ["gamma", "night", "temperature", "kelvin", "warm", "color", "blue light"]
                        width: parent.width
                        text: SessionData.nightModeAutoEnabled ? I18n.tr("Night Temperature") : I18n.tr("Color Temperature")
                        description: SessionData.nightModeAutoEnabled ? I18n.tr("Color temperature for night mode") : I18n.tr("Warm color temperature to apply")
                        minimum: 2500
                        maximum: 6000
                        step: 100
                        unit: "K"
                        value: SessionData.nightModeTemperature
                        onSliderValueChanged: newValue => {
                            SessionData.setNightModeTemperature(newValue);
                            if (SessionData.nightModeHighTemperature < newValue)
                                SessionData.setNightModeHighTemperature(newValue);
                        }
                    }

                    SettingsSliderRow {
                        id: dayTempSlider
                        settingKey: "nightModeHighTemperature"
                        tags: ["gamma", "day", "temperature", "kelvin", "color"]
                        width: parent.width
                        text: I18n.tr("Day Temperature")
                        description: I18n.tr("Color temperature during the day")
                        minimum: SessionData.nightModeTemperature
                        maximum: 10000
                        step: 100
                        unit: "K"
                        value: Math.max(SessionData.nightModeHighTemperature, SessionData.nightModeTemperature)
                        visible: SessionData.nightModeAutoEnabled
                        onSliderValueChanged: newValue => SessionData.setNightModeHighTemperature(newValue)
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Automation")
                iconName: "schedule"
                width: parent.width
                visible: DisplayService.gammaControlAvailable

                VgsToggle {
                    horizontalPadding: 0
                    rowHoverHighlight: false
                    id: automaticToggle
                    width: parent.width
                    text: I18n.tr("Automatic Control")
                    description: I18n.tr("Switch temperatures on a time or location schedule")
                    checked: SessionData.nightModeAutoEnabled
                    onToggled: checked => {
                        if (checked && !DisplayService.nightModeEnabled) {
                            DisplayService.toggleNightMode();
                        } else if (!checked && DisplayService.nightModeEnabled) {
                            DisplayService.toggleNightMode();
                        }
                        SessionData.setNightModeAutoEnabled(checked);
                    }

                    Connections {
                        target: SessionData
                        function onNightModeAutoEnabledChanged() {
                            automaticToggle.checked = SessionData.nightModeAutoEnabled;
                        }
                    }
                }

                Column {
                    id: automaticSettings
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: SessionData.nightModeAutoEnabled

                    Item {
                        width: parent.width
                        height: 45 + Theme.spacingM

                        VgsTabBar {
                            id: modeTabBarNight
                            width: 200
                            height: 45
                            anchors.horizontalCenter: parent.horizontalCenter
                            model: [
                                {
                                    "text": I18n.tr("Time"),
                                    "icon": "access_time"
                                },
                                {
                                    "text": I18n.tr("Location"),
                                    "icon": "place"
                                }
                            ]

                            Component.onCompleted: {
                                currentIndex = SessionData.nightModeAutoMode === "location" ? 1 : 0;
                                Qt.callLater(updateIndicator);
                            }

                            onTabClicked: index => {
                                DisplayService.setNightModeAutomationMode(index === 1 ? "location" : "time");
                                currentIndex = index;
                            }

                            Connections {
                                target: SessionData
                                function onNightModeAutoModeChanged() {
                                    modeTabBarNight.currentIndex = SessionData.nightModeAutoMode === "location" ? 1 : 0;
                                    Qt.callLater(modeTabBarNight.updateIndicator);
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: SessionData.nightModeAutoMode === "time"

                        Column {
                            spacing: Theme.spacingXS
                            anchors.horizontalCenter: parent.horizontalCenter

                            Row {
                                spacing: Theme.spacingM

                                StyledText {
                                    text: ""
                                    width: 50
                                    height: 20
                                }

                                StyledText {
                                    text: I18n.tr("Hour")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    width: 70
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                StyledText {
                                    text: I18n.tr("Minute")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    width: 70
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }

                            Row {
                                spacing: Theme.spacingM

                                StyledText {
                                    text: I18n.tr("Start")
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    width: 50
                                    height: 40
                                    verticalAlignment: Text.AlignVCenter
                                }

                                VgsDropdown {
                                    dropdownWidth: 70
                                    currentValue: SessionData.nightModeStartHour.toString()
                                    options: {
                                        var hours = [];
                                        for (var i = 0; i < 24; i++) {
                                            hours.push(i.toString());
                                        }
                                        return hours;
                                    }
                                    onValueChanged: value => {
                                        SessionData.setNightModeStartHour(parseInt(value));
                                    }
                                }

                                VgsDropdown {
                                    dropdownWidth: 70
                                    currentValue: SessionData.nightModeStartMinute.toString().padStart(2, '0')
                                    options: {
                                        var minutes = [];
                                        for (var i = 0; i < 60; i += 5) {
                                            minutes.push(i.toString().padStart(2, '0'));
                                        }
                                        return minutes;
                                    }
                                    onValueChanged: value => {
                                        SessionData.setNightModeStartMinute(parseInt(value));
                                    }
                                }
                            }

                            Row {
                                spacing: Theme.spacingM

                                StyledText {
                                    text: I18n.tr("End")
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    width: 50
                                    height: 40
                                    verticalAlignment: Text.AlignVCenter
                                }

                                VgsDropdown {
                                    dropdownWidth: 70
                                    currentValue: SessionData.nightModeEndHour.toString()
                                    options: {
                                        var hours = [];
                                        for (var i = 0; i < 24; i++) {
                                            hours.push(i.toString());
                                        }
                                        return hours;
                                    }
                                    onValueChanged: value => {
                                        SessionData.setNightModeEndHour(parseInt(value));
                                    }
                                }

                                VgsDropdown {
                                    dropdownWidth: 70
                                    currentValue: SessionData.nightModeEndMinute.toString().padStart(2, '0')
                                    options: {
                                        var minutes = [];
                                        for (var i = 0; i < 60; i += 5) {
                                            minutes.push(i.toString().padStart(2, '0'));
                                        }
                                        return minutes;
                                    }
                                    onValueChanged: value => {
                                        SessionData.setNightModeEndMinute(parseInt(value));
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        property bool isLocationMode: SessionData.nightModeAutoMode === "location"
                        visible: isLocationMode
                        spacing: Theme.spacingM
                        width: parent.width

                        VgsToggle {
                            horizontalPadding: 0
                            rowHoverHighlight: false
                            id: ipLocationToggle
                            width: parent.width
                            text: I18n.tr("Use IP Location")
                            description: I18n.tr("Detect your location automatically from your IP address")
                            checked: SessionData.nightModeUseIPLocation || false
                            onToggled: checked => {
                                SessionData.setNightModeUseIPLocation(checked);
                            }

                            Connections {
                                target: SessionData
                                function onNightModeUseIPLocationChanged() {
                                    ipLocationToggle.checked = SessionData.nightModeUseIPLocation;
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingM
                            visible: !SessionData.nightModeUseIPLocation

                            StyledText {
                                text: I18n.tr("Manual Coordinates")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                            }

                            Row {
                                spacing: Theme.spacingL

                                Column {
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: I18n.tr("Latitude")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    VgsTextField {
                                        width: 120
                                        height: 40
                                        text: SessionData.latitude.toString()
                                        placeholderText: "0.0"
                                        onEditingFinished: {
                                            const lat = parseFloat(text);
                                            if (!isNaN(lat) && lat >= -90 && lat <= 90 && lat !== SessionData.latitude) {
                                                SessionData.setLatitude(lat);
                                            }
                                        }
                                    }
                                }

                                Column {
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: I18n.tr("Longitude")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    VgsTextField {
                                        width: 120
                                        height: 40
                                        text: SessionData.longitude.toString()
                                        placeholderText: "0.0"
                                        onEditingFinished: {
                                            const lon = parseFloat(text);
                                            if (!isNaN(lon) && lon >= -180 && lon <= 180 && lon !== SessionData.longitude) {
                                                SessionData.setLongitude(lon);
                                            }
                                        }
                                    }
                                }
                            }

                            StyledText {
                                text: I18n.tr("Night mode follows sunrise and sunset at these coordinates")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                width: parent.width
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Current Status")
                iconName: DisplayService.gammaIsDay ? "light_mode" : "dark_mode"
                width: parent.width
                visible: DisplayService.gammaControlAvailable && SessionData.nightModeAutoEnabled && DisplayService.nightModeEnabled && DisplayService.gammaCurrentTemp > 0

                Column {
                    id: gammaStatusSection
                    width: parent.width
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        Rectangle {
                            width: (parent.width - Theme.spacingM) / 2
                            height: tempColumn.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: tempColumn
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: "device_thermostat"
                                    size: Theme.iconSize
                                    color: Theme.primary
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: DisplayService.gammaCurrentTemp + "K"
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Current Temperature")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }

                        Rectangle {
                            width: (parent.width - Theme.spacingM) / 2
                            height: periodColumn.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: periodColumn
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: DisplayService.gammaIsDay ? "wb_sunny" : "nightlight"
                                    size: Theme.iconSize
                                    color: DisplayService.gammaIsDay ? Theme.warning : Theme.primary
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: DisplayService.gammaIsDay ? I18n.tr("Daytime") : I18n.tr("Night")
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Current Period")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: SessionData.nightModeAutoMode === "location" && (DisplayService.gammaSunriseTime || DisplayService.gammaSunsetTime)

                        Rectangle {
                            width: (parent.width - Theme.spacingM) / 2
                            height: sunriseColumn.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            visible: DisplayService.gammaSunriseTime

                            Column {
                                id: sunriseColumn
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: "wb_twilight"
                                    size: Theme.iconSize
                                    color: Theme.error
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: root.formatGammaTime(DisplayService.gammaSunriseTime)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Sunrise")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }

                        Rectangle {
                            width: (parent.width - Theme.spacingM) / 2
                            height: sunsetColumn.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            visible: DisplayService.gammaSunsetTime

                            Column {
                                id: sunsetColumn
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: "wb_twilight"
                                    size: Theme.iconSize
                                    color: Theme.info
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: root.formatGammaTime(DisplayService.gammaSunsetTime)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Sunset")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: nextChangeRow.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh
                        visible: DisplayService.gammaNextTransition

                        Row {
                            id: nextChangeRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            VgsIcon {
                                name: "schedule"
                                size: Theme.iconSize
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                spacing: Theme.spacingXXS
                                anchors.verticalCenter: parent.verticalCenter

                                StyledText {
                                    text: I18n.tr("Next Transition")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    text: root.formatGammaTime(DisplayService.gammaNextTransition)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
