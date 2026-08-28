import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

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
                tab: "motion"
                tags: ["animation", "variant", "style", "slide", "fluent", "dynamic", "motion"]
                settingKey: "animationVariant"

                SettingsChoiceRow {
                    text: I18n.tr("Animation Style")
                    model: [I18n.tr("Material"), I18n.tr("Fluent"), I18n.tr("Dynamic")]
                    currentIndex: SettingsData.animationVariant
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            SettingsData.set("animationVariant", index);
                    }
                }

            }

            SettingsCard {
                tab: "motion"
                tags: ["animation", "motion", "effect", "slide", "directional", "depth", "spring", "physics"]
                settingKey: "motionEffect"

                SettingsChoiceRow {
                    text: I18n.tr("Motion Effects")
                    model: [I18n.tr("Standard"), I18n.tr("Directional"), I18n.tr("Depth")]
                    currentIndex: SettingsData.motionEffect
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            SettingsData.set("motionEffect", index);
                    }
                }

            }

            SettingsCard {
                tab: "motion"
                tags: ["animation", "speed", "motion", "duration"]
                settingKey: "animationSpeed"

                SettingsChoiceRow {
                    text: I18n.tr("Animation Speed")
                    model: [I18n.tr("None"), I18n.tr("Short"), I18n.tr("Medium"), I18n.tr("Long"), I18n.tr("Custom")]
                    currentIndex: SettingsData.animationSpeed
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            SettingsData.set("animationSpeed", index);
                    }
                }

                SettingsDivider {}

                SettingsSliderRow {
                    id: durationSlider
                    tab: "motion"
                    tags: ["animation", "duration", "custom", "speed"]
                    settingKey: "customAnimationDuration"
                    text: I18n.tr("Custom Duration")
                    description: I18n.tr("Base animation duration; dragging switches the speed to Custom")
                    minimum: 0
                    maximum: 1000
                    value: Theme.currentAnimationBaseDuration
                    unit: "ms"
                    defaultValue: 200
                    onSliderValueChanged: newValue => {
                        SettingsData.set("animationSpeed", SettingsData.AnimationSpeed.Custom);
                        SettingsData.set("customAnimationDuration", newValue);
                    }

                    Connections {
                        target: SettingsData
                        function onAnimationSpeedChanged() {
                            if (SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            durationSlider.value = Theme.currentAnimationBaseDuration;
                        }
                    }

                    Connections {
                        target: Theme
                        function onCurrentAnimationBaseDurationChanged() {
                            if (SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            durationSlider.value = Theme.currentAnimationBaseDuration;
                        }
                    }
                }

                SettingsDivider {}

                SettingsToggleRow {
                    tab: "motion"
                    tags: ["animation", "sync", "popout", "modal", "global"]
                    settingKey: "syncComponentAnimationSpeeds"
                    text: I18n.tr("Sync Popouts & Modals")
                    description: I18n.tr("Popouts and modals follow the global speed; turn off to tune them separately")
                    checked: SettingsData.syncComponentAnimationSpeeds
                    onToggled: checked => SettingsData.set("syncComponentAnimationSpeeds", checked)
                }
            }

            SettingsCard {
                tab: "motion"
                tags: ["animation", "speed", "motion", "duration", "popout", "sync"]
                settingKey: "popoutAnimationSpeed"

                SettingsChoiceRow {
                    text: I18n.tr("%1 Animation Speed").arg(I18n.tr("Popouts"))
                    model: [I18n.tr("None"), I18n.tr("Short"), I18n.tr("Medium"), I18n.tr("Long"), I18n.tr("Custom")]
                    currentIndex: SettingsData.popoutAnimationSpeed
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        if (SettingsData.syncComponentAnimationSpeeds)
                            SettingsData.set("syncComponentAnimationSpeeds", false);
                        SettingsData.set("popoutAnimationSpeed", index);
                    }
                }

                SettingsDivider {}

                SettingsSliderRow {
                    id: popoutDurationSlider
                    tab: "motion"
                    tags: ["animation", "duration", "custom", "speed", "popout"]
                    settingKey: "popoutCustomAnimationDuration"
                    text: I18n.tr("Custom Duration")
                    description: I18n.tr("Duration used by %1 when their speed is Custom").arg(I18n.tr("Popouts"))
                    minimum: 0
                    maximum: 1000
                    value: Theme.popoutAnimationDuration
                    unit: "ms"
                    defaultValue: 150
                    onSliderValueChanged: newValue => {
                        if (SettingsData.syncComponentAnimationSpeeds)
                            SettingsData.set("syncComponentAnimationSpeeds", false);
                        SettingsData.set("popoutAnimationSpeed", SettingsData.AnimationSpeed.Custom);
                        SettingsData.set("popoutCustomAnimationDuration", newValue);
                    }

                    Connections {
                        target: SettingsData
                        function onPopoutAnimationSpeedChanged() {
                            if (SettingsData.popoutAnimationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            popoutDurationSlider.value = Theme.popoutAnimationDuration;
                        }
                    }

                    Connections {
                        target: Theme
                        function onPopoutAnimationDurationChanged() {
                            if (!SettingsData.syncComponentAnimationSpeeds && SettingsData.popoutAnimationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            popoutDurationSlider.value = Theme.popoutAnimationDuration;
                        }
                    }
                }
            }

            SettingsCard {
                tab: "motion"
                tags: ["animation", "speed", "motion", "duration", "modal", "sync"]
                settingKey: "modalAnimationSpeed"

                SettingsChoiceRow {
                    text: I18n.tr("%1 Animation Speed").arg(I18n.tr("Modals"))
                    model: [I18n.tr("None"), I18n.tr("Short"), I18n.tr("Medium"), I18n.tr("Long"), I18n.tr("Custom")]
                    currentIndex: SettingsData.modalAnimationSpeed
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        if (SettingsData.syncComponentAnimationSpeeds)
                            SettingsData.set("syncComponentAnimationSpeeds", false);
                        SettingsData.set("modalAnimationSpeed", index);
                    }
                }

                SettingsDivider {}

                SettingsSliderRow {
                    id: modalDurationSlider
                    tab: "motion"
                    tags: ["animation", "duration", "custom", "speed", "modal"]
                    settingKey: "modalCustomAnimationDuration"
                    text: I18n.tr("Custom Duration")
                    description: I18n.tr("Duration used by %1 when their speed is Custom").arg(I18n.tr("Modals"))
                    minimum: 0
                    maximum: 1000
                    value: Theme.modalAnimationDuration
                    unit: "ms"
                    defaultValue: 150
                    onSliderValueChanged: newValue => {
                        if (SettingsData.syncComponentAnimationSpeeds)
                            SettingsData.set("syncComponentAnimationSpeeds", false);
                        SettingsData.set("modalAnimationSpeed", SettingsData.AnimationSpeed.Custom);
                        SettingsData.set("modalCustomAnimationDuration", newValue);
                    }

                    Connections {
                        target: SettingsData
                        function onModalAnimationSpeedChanged() {
                            if (SettingsData.modalAnimationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            modalDurationSlider.value = Theme.modalAnimationDuration;
                        }
                    }

                    Connections {
                        target: Theme
                        function onModalAnimationDurationChanged() {
                            if (!SettingsData.syncComponentAnimationSpeeds && SettingsData.modalAnimationSpeed === SettingsData.AnimationSpeed.Custom)
                                return;
                            modalDurationSlider.value = Theme.modalAnimationDuration;
                        }
                    }
                }
            }

            SettingsCard {
                tab: "motion"
                tags: ["animation", "ripple", "effect", "material", "feedback"]
                title: I18n.tr("Ripple Effects")
                settingKey: "enableRippleEffects"
                iconName: "radio_button_unchecked"

                SettingsToggleRow {
                    tab: "motion"
                    tags: ["animation", "ripple", "effect", "material", "click"]
                    settingKey: "enableRippleEffects"
                    text: I18n.tr("Ripple Effects")
                    description: I18n.tr("Material Design ripple animations on interactive elements")
                    checked: SettingsData.enableRippleEffects ?? true
                    onToggled: newValue => SettingsData.set("enableRippleEffects", newValue)
                }
            }
        }
    }
}
