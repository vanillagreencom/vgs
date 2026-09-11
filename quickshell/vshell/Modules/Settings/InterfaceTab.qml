import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root
    property var parentModal: null

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mainColumn.height + Theme.spacingXL

        Column {
            id: mainColumn
            width: Math.min(760, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Theme.spacingS
            spacing: Theme.spacingXL

            SettingsCard {
                title: I18n.tr("Flyouts & Dropdowns")
                iconName: "web_asset"
                settingKey: "popupSurfaces"
                width: parent.width

                SettingsSliderRow {
                    settingKey: "popupTransparency"
                    tags: ["theme", "flyout", "dropdown", "popup", "popout", "menu", "transparency", "opacity"]
                    text: I18n.tr("Surface Opacity")
                    description: SettingsData.popupGlassEffect && SettingsData.blurEnabled ? I18n.tr("100% uses the standard glass opacity.") : I18n.tr("Opacity of menus and popups.")
                    value: Math.round(SettingsData.popupTransparency * 100)
                    minimum: 8
                    maximum: 100
                    unit: "%"
                    defaultValue: 100
                    onSliderValueChanged: newValue => SettingsData.set("popupTransparency", newValue / 100)
                }

                SettingsToggleRow {
                    settingKey: "blurEnabled"
                    tags: ["theme", "flyout", "dropdown", "popup", "popout", "menu", "blur", "glass", "frosted"]
                    text: I18n.tr("Background Blur")
                    description: BlurService.available
                        ? I18n.tr("Soften the background behind menus.")
                        : CompositorService.isNiri
                            ? I18n.tr("Niri does not provide compositor blur")
                            : I18n.tr("Your compositor does not support blur.")
                    checked: SettingsData.blurEnabled
                    enabled: BlurService.available
                    opacity: enabled ? 1.0 : 0.5
                    onToggled: checked => SettingsData.set("blurEnabled", checked)
                }

                SettingsSliderRow {
                    settingKey: "popupBlurStrength"
                    tags: ["theme", "flyout", "dropdown", "popup", "popout", "menu", "blur", "glass", "frosted"]
                    text: I18n.tr("Background Blur Level")
                    description: I18n.tr("Adjust blur without changing opacity.")
                    value: Math.round(SettingsData.popupBlurStrength * 100)
                    minimum: 0
                    maximum: 100
                    unit: "%"
                    defaultValue: 65
                    enabled: BlurService.available && SettingsData.blurEnabled
                    opacity: enabled ? 1.0 : 0.5
                    onSliderValueChanged: newValue => SettingsData.set("popupBlurStrength", newValue / 100)
                }

                SettingsToggleRow {
                    settingKey: "popupGlassEffect"
                    tags: ["theme", "flyout", "dropdown", "popup", "popout", "menu", "blur", "glass", "liquid", "frosted"]
                    text: I18n.tr("Glass Effect")
                    description: I18n.tr("Tinted glass with soft highlights.")
                    checked: SettingsData.popupGlassEffect
                    enabled: BlurService.available && SettingsData.blurEnabled
                    opacity: enabled ? 1.0 : 0.5
                    onToggled: checked => SettingsData.set("popupGlassEffect", checked)
                }
            }

            SettingsCard {
                title: I18n.tr("Surface Shape")
                iconName: "rounded_corner"
                settingKey: "surfaceGeometry"
                width: parent.width
                tags: ["surface", "shape", "radius", "rounding", "border", "thickness", "quickshell", "hyprland", "window"]

                SettingsSliderRow {
                    settingKey: "cornerRadius"
                    tags: ["surface", "shape", "radius", "rounding", "corner", "container", "quickshell", "hyprland", "niri", "compositor", "window", "group", "tab"]
                    text: I18n.tr("Container Radius")
                    description: CompositorService.isHyprland ? I18n.tr("Corners of VGS surfaces, app windows, and group tabs.") : I18n.tr("Corners of VGS surfaces and app windows.")
                    value: SettingsData.effectiveContainerRadius
                    minimum: 0
                    maximum: 20
                    unit: "px"
                    defaultValue: 15
                    onSliderValueChanged: newValue => SettingsData.set("cornerRadius", newValue)
                }

                SettingsSliderRow {
                    settingKey: "controlRadius"
                    tags: ["surface", "shape", "radius", "rounding", "corner", "button", "toggle", "control", "field", "quickshell"]
                    text: I18n.tr("Control Radius")
                    description: I18n.tr("Corners of buttons and controls.")
                    value: SettingsData.effectiveControlRadius
                    minimum: 0
                    maximum: 20
                    unit: "px"
                    defaultValue: 10
                    onSliderValueChanged: newValue => SettingsData.set("controlRadius", newValue)
                }

                SettingsSliderRow {
                    settingKey: "surfaceBorderWidth"
                    tags: ["surface", "shape", "border", "thickness", "quickshell", "hyprland", "niri", "compositor", "window"]
                    text: I18n.tr("Border Thickness")
                    description: I18n.tr("Borders of VGS surfaces and app windows.")
                    value: Math.max(0, Math.round(SettingsData.surfaceBorderWidth))
                    minimum: 0
                    maximum: 10
                    unit: "px"
                    defaultValue: 1
                    onSliderValueChanged: newValue => SettingsData.set("surfaceBorderWidth", newValue)
                }
            }
        }
    }
}
