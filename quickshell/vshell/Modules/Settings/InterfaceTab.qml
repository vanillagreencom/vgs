import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import "../../Common/settings/SurfaceGeometry.js" as SurfaceGeometry

Item {
    id: root
    property var parentModal: null

    readonly property string surfaceGeometryTarget: SettingsData.normalizedSurfaceGeometryTarget
    readonly property bool shapeTargetsQuickshell: SurfaceGeometry.appliesToQuickshell(surfaceGeometryTarget)
    readonly property bool shapeTargetsCompositorOnly: surfaceGeometryTarget === "compositor" && SurfaceGeometry.appliesToCompositor(surfaceGeometryTarget)
    readonly property int compositorRadiusOverride: CompositorService.isNiri
        ? SettingsData.niriLayoutRadiusOverride : SettingsData.hyprlandLayoutRadiusOverride
    readonly property int compositorBorderOverride: CompositorService.isNiri
        ? SettingsData.niriLayoutBorderSize : SettingsData.hyprlandLayoutBorderSize

    function geometryTargetIndex() {
        return SurfaceGeometry.targetIndex(surfaceGeometryTarget);
    }

    function setGeometryTargetIndex(index) {
        SettingsData.set("surfaceGeometryTarget", SurfaceGeometry.targetFromIndex(index));
    }

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

                SettingsChoiceRow {
                    settingKey: "surfaceGeometryTarget"
                    tags: ["surface", "shape", "sync", "quickshell", "compositor", "hyprland", "niri"]
                    text: I18n.tr("Apply To")
                    description: I18n.tr("Apply these settings to:")
                    model: [I18n.tr("Both"), I18n.tr("Quickshell"), I18n.tr("Compositor")]
                    currentIndex: root.geometryTargetIndex()
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            root.setGeometryTargetIndex(index);
                    }
                }

                SettingsSliderRow {
                    settingKey: "cornerRadius"
                    tags: ["surface", "shape", "radius", "rounding", "corner", "container", "quickshell", "hyprland"]
                    text: root.surfaceGeometryTarget === "sync" ? I18n.tr("Container Radius") : I18n.tr("Quickshell Container Radius")
                    description: root.surfaceGeometryTarget === "sync" ? I18n.tr("Corners of VGS and app windows.") : I18n.tr("Corners of VGS windows and menus.")
                    visible: root.shapeTargetsQuickshell
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
                    visible: root.shapeTargetsQuickshell
                    value: SettingsData.effectiveControlRadius
                    minimum: 0
                    maximum: 20
                    unit: "px"
                    defaultValue: 10
                    onSliderValueChanged: newValue => SettingsData.set("controlRadius", newValue)
                }

                SettingsSliderRow {
                    settingKey: "surfaceBorderWidth"
                    tags: ["surface", "shape", "border", "thickness", "quickshell", "hyprland"]
                    text: root.surfaceGeometryTarget === "sync" ? I18n.tr("Border Thickness") : I18n.tr("Quickshell Border Thickness")
                    description: root.surfaceGeometryTarget === "sync" ? I18n.tr("Borders of VGS and app windows.") : I18n.tr("Borders of VGS windows and menus.")
                    visible: root.shapeTargetsQuickshell
                    value: Math.max(0, Math.round(SettingsData.surfaceBorderWidth))
                    minimum: 0
                    maximum: 10
                    unit: "px"
                    defaultValue: 1
                    onSliderValueChanged: newValue => SettingsData.set("surfaceBorderWidth", newValue)
                }

                SettingsSliderRow {
                    settingKey: CompositorService.isNiri ? "niriLayoutRadiusOverride" : "hyprlandLayoutRadiusOverride"
                    tags: ["surface", "shape", "radius", "rounding", "corner", "compositor", "hyprland", "niri", "window"]
                    text: CompositorService.isNiri ? I18n.tr("Niri Window Radius") : I18n.tr("Hyprland Window Radius")
                    description: I18n.tr("Corners of app windows.")
                    visible: root.shapeTargetsCompositorOnly
                    value: Math.min(20, SurfaceGeometry.effectiveCompositorRadius(root.surfaceGeometryTarget,
                        SettingsData.cornerRadius, root.compositorRadiusOverride))
                    minimum: 0
                    maximum: 20
                    unit: "px"
                    defaultValue: Math.min(20, Math.max(0, Math.round(SettingsData.cornerRadius)))
                    onSliderValueChanged: newValue => SettingsData.set(
                        CompositorService.isNiri ? "niriLayoutRadiusOverride" : "hyprlandLayoutRadiusOverride", newValue)
                }

                SettingsSliderRow {
                    settingKey: CompositorService.isNiri ? "niriLayoutBorderSize" : "hyprlandLayoutBorderSize"
                    tags: ["surface", "shape", "border", "thickness", "compositor", "hyprland", "niri", "window"]
                    text: CompositorService.isNiri ? I18n.tr("Niri Border Thickness") : I18n.tr("Hyprland Border Thickness")
                    description: I18n.tr("Borders of app windows.")
                    visible: root.shapeTargetsCompositorOnly
                    value: SurfaceGeometry.effectiveCompositorBorderWidth(root.surfaceGeometryTarget,
                        SettingsData.surfaceBorderWidth, root.compositorBorderOverride)
                    minimum: 0
                    maximum: 10
                    unit: "px"
                    defaultValue: Math.max(0, Math.round(SettingsData.surfaceBorderWidth))
                    onSliderValueChanged: newValue => SettingsData.set(
                        CompositorService.isNiri ? "niriLayoutBorderSize" : "hyprlandLayoutBorderSize", newValue)
                }
            }
        }
    }
}
