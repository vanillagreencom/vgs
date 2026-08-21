import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root
    property var parentModal: null
    property string saveName: "custom-theme"
    property string selectedWallpaper: SessionData.wallpaperPath || VGSThemeService.selectedWallpaper || ""
    property bool revertConfirmPending: false

    property var matugenModeOptions: [
        { label: I18n.tr("Match the image"), value: "auto" },
        { label: I18n.tr("Dark"), value: "dark" },
        { label: I18n.tr("Light"), value: "light" }
    ]
    property var matugenSchemeOptions: [
        { label: I18n.tr("Tonal Spot"), value: "scheme-tonal-spot" },
        { label: I18n.tr("Content"), value: "scheme-content" },
        { label: I18n.tr("Expressive"), value: "scheme-expressive" },
        { label: I18n.tr("Fidelity"), value: "scheme-fidelity" },
        { label: I18n.tr("Fruit Salad"), value: "scheme-fruit-salad" },
        { label: I18n.tr("Monochrome"), value: "scheme-monochrome" },
        { label: I18n.tr("Neutral"), value: "scheme-neutral" },
        { label: I18n.tr("Rainbow"), value: "scheme-rainbow" },
        { label: I18n.tr("Vibrant"), value: "scheme-vibrant" }
    ]
    property var matugenContrastOptions: [
        { label: I18n.tr("Low (-0.5)"), value: -0.5 },
        { label: I18n.tr("Default (0)"), value: 0 },
        { label: I18n.tr("Medium (+0.25)"), value: 0.25 },
        { label: I18n.tr("High (+0.5)"), value: 0.5 },
        { label: I18n.tr("Max (+1.0)"), value: 1.0 }
    ]

    readonly property var currentEntry: VGSThemeService.currentBlueprint

    function optionLabel(options, value, fallback) {
        for (let i = 0; i < options.length; i++) {
            if (options[i].value === value)
                return options[i].label;
        }
        return fallback || (options.length > 0 ? options[0].label : "");
    }

    function optionValue(options, label, fallback) {
        for (let i = 0; i < options.length; i++) {
            if (options[i].label === label)
                return options[i].value;
        }
        return fallback;
    }

    function imageUrl(path) {
        if (!path || path.startsWith("#"))
            return "";
        if (path.startsWith("file://"))
            return path;
        return "file://" + path.split('/').map(s => encodeURIComponent(s)).join('/');
    }

    // Preview hashes churn when apps/ files change; render missing ones when
    // the tab opens too, not only from the picker. One deferred kick after the
    // fresh list lands, so a failing generator can't retry-loop.
    property bool _previewKickDone: false

    Component.onCompleted: {
        VGSThemeService.refresh();
        VGSThemeService.generateMissingPreviews();
    }

    function showThemeCatalog() {
        themeCatalogLoader.active = true;
        if (themeCatalogLoader.item)
            themeCatalogLoader.item.show();
    }

    LazyLoader {
        id: themeCatalogLoader
        active: false

        ThemeCatalogBrowser {
            id: themeCatalogBrowser
            Component.onCompleted: themeCatalogBrowser.parentModal = root.parentModal
        }
    }

    Timer {
        id: revertConfirmTimer
        interval: 4000
        onTriggered: root.revertConfirmPending = false
    }

    Connections {
        target: VGSThemeService
        function onBlueprintsLoaded() {
            if (root._previewKickDone)
                return;
            root._previewKickDone = true;
            VGSThemeService.generateMissingPreviews();
        }
    }

    Connections {
        target: SessionData
        function onWallpaperPathChanged() {
            root.selectedWallpaper = SessionData.wallpaperPath;
        }
    }

    Connections {
        target: VGSThemeService
        function onApplyCompleted(success, message) {
            if (success)
                ToastService.showInfo(message);
            else
                ToastService.showError(I18n.tr("VGS theme error"), message);
        }
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

            ThemeSubNav {
                width: parent.width
                parentModal: root.parentModal
                activeId: "theme"
            }

            SettingsCard {
                title: I18n.tr("Current Theme")
                iconName: "palette"
                settingKey: "vgsCurrentTheme"
                width: parent.width

                Row {
                    width: parent.width
                    spacing: Theme.spacingL

                    StyledRect {
                        id: currentPreview
                        width: 220
                        height: 124
                        radius: Theme.cornerRadius
                        color: root.currentEntry.background || Theme.surfaceContainerHighest
                        clip: true

                        Image {
                            anchors.fill: parent
                            visible: (root.currentEntry.preview || "") !== ""
                            source: root.currentEntry.preview ? "file://" + root.currentEntry.preview : ""
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 440
                            asynchronous: true
                            cache: false
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS
                            visible: (root.currentEntry.preview || "") === ""

                            VgsSpinner {
                                anchors.horizontalCenter: parent.horizontalCenter
                                size: 22
                                visible: VGSThemeService.previewsGenerating
                                running: VGSThemeService.previewsGenerating
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: VGSThemeService.previewsGenerating ? I18n.tr("Rendering…") : I18n.tr("No preview")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    Column {
                        width: parent.width - currentPreview.width - Theme.spacingL
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                width: Math.min(implicitWidth, parent.width - modifiedBadge.width - Theme.spacingS)
                                text: VGSThemeService.currentTheme.name || I18n.tr("unknown")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Rectangle {
                                id: modifiedBadge
                                visible: root.currentEntry.modified === true
                                width: visible ? modifiedBadgeText.implicitWidth + Theme.spacingS * 2 : 0
                                height: 18
                                radius: 9
                                color: Theme.primaryContainer
                                anchors.verticalCenter: parent.verticalCenter

                                StyledText {
                                    id: modifiedBadgeText
                                    anchors.centerIn: parent
                                    text: I18n.tr("Modified")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceText
                                }
                            }
                        }

                        Row {
                            spacing: Theme.spacingS

                            Rectangle {
                                width: modeText.implicitWidth + Theme.spacingM
                                height: 22
                                radius: 11
                                color: Theme.surfaceVariant

                                StyledText {
                                    id: modeText
                                    anchors.centerIn: parent
                                    text: (VGSThemeService.currentTheme.mode || "dark") === "light" ? I18n.tr("Light") : I18n.tr("Dark")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Rectangle {
                                width: sourceText.implicitWidth + Theme.spacingM
                                height: 22
                                radius: 11
                                color: (VGSThemeService.currentTheme.source || "generated") === "curated" ? Theme.primaryContainer : Theme.surfaceVariant

                                StyledText {
                                    id: sourceText
                                    anchors.centerIn: parent
                                    text: (VGSThemeService.currentTheme.source || "generated") === "curated" ? I18n.tr("Curated") : I18n.tr("Generated")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: (root.currentEntry.pair || "") !== ""
                            text: I18n.tr("Pairs with %1 for light/dark toggle").arg(root.currentEntry.pair || "")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                    }
                }

                Flow {
                    spacing: Theme.spacingS
                    width: parent.width

                    // Opens the full-screen switcher, not the dash tab: that is
                    // the browse surface, and the same one the shortcut below
                    // opens. The dash stays the fallback for a shell root that
                    // has not registered it.
                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Browse Themes")
                        onClicked: {
                            if (ModalManager.showSwitcher("theme"))
                                return;
                            const bar = KeyboardFocus.getPreferredBar("clockButtonRef") || KeyboardFocus.getPreferredBar();
                            if (bar)
                                bar.triggerDashTab(SettingsData.dashTabIndexForId("themes"));
                        }
                    }

                    // Packages ship one theme, so "Browse Themes" alone browses a
                    // single entry on a fresh install. This is the discovery path
                    // for the rest.
                    VgsButton {
                        variant: "secondary"
                        iconName: "cloud_download"
                        text: I18n.tr("Download More Themes")
                        onClicked: root.showThemeCatalog()
                    }

                    VgsButton {
                        variant: "secondary"
                        visible: (root.currentEntry.pair || "") !== ""
                        text: (VGSThemeService.currentTheme.mode || "dark") === "light" ? I18n.tr("Switch to Dark") : I18n.tr("Switch to Light")
                        enabled: !VGSThemeService.busy
                        onClicked: VGSThemeService.applyBlueprint(root.currentEntry.pair)
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Duplicate Theme")
                        enabled: !VGSThemeService.busy && (VGSThemeService.currentTheme.name || "") !== ""
                        onClicked: VGSThemeService.duplicateTheme(VGSThemeService.currentTheme.name)
                    }

                    VgsButton {
                        variant: "secondary"
                        iconName: "restart_alt"
                        visible: root.currentEntry.modified === true && root.currentEntry.builtin === true
                        text: root.revertConfirmPending ? I18n.tr("Confirm Revert?") : I18n.tr("Revert to Default")
                        enabled: !VGSThemeService.busy
                        onClicked: {
                            if (root.revertConfirmPending) {
                                root.revertConfirmPending = false;
                                revertConfirmTimer.stop();
                                VGSThemeService.revertTheme(VGSThemeService.currentTheme.name);
                            } else {
                                root.revertConfirmPending = true;
                                revertConfirmTimer.restart();
                            }
                        }
                    }
                }

                SwitcherShortcutRow {
                    action: "spawn vshell ipc call theme-switcher toggle"
                    text: I18n.tr("Theme Switcher Shortcut")
                    description: I18n.tr("Opens the full-screen theme switcher")
                    bindDescription: I18n.tr("Theme switcher")
                    panelWindow: root.parentModal
                }
            }

            SettingsCard {
                title: I18n.tr("Theme From Image")
                iconName: "auto_awesome"
                settingKey: "wallpaper"
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Pick any image and VGS builds a matching color theme for your whole desktop. Try it instantly — nothing is saved until you say so.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingL

                    StyledRect {
                        width: 180
                        height: 110
                        radius: Theme.cornerRadius
                        color: root.selectedWallpaper.startsWith("#") ? root.selectedWallpaper : Theme.surfaceContainerHighest
                        clip: true

                        Image {
                            anchors.fill: parent
                            anchors.margins: 1
                            source: root.imageUrl(root.selectedWallpaper)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: root.selectedWallpaper !== "" && !root.selectedWallpaper.startsWith("#")
                        }

                        VgsIcon {
                            anchors.centerIn: parent
                            name: "image"
                            size: Theme.iconSizeLarge
                            color: Theme.surfaceVariantText
                            visible: root.selectedWallpaper === ""
                        }
                    }

                    Column {
                        width: parent.width - 180 - Theme.spacingL
                        spacing: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            width: parent.width
                            text: root.selectedWallpaper ? root.selectedWallpaper.split('/').pop() : I18n.tr("No wallpaper selected")
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            elide: Text.ElideMiddle
                        }

                        StyledText {
                            width: parent.width
                            text: root.selectedWallpaper || I18n.tr("Choose an image, then set it as wallpaper or generate a full app palette.")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideMiddle
                        }
                    }
                }

                SettingsWallpaperPicker {
                    width: parent.width
                    path: root.selectedWallpaper
                    showFillMode: false
                    placeholderText: I18n.tr("Image path")
                    browserTitle: I18n.tr("Pick an image")
                    onPathSelected: path => root.selectedWallpaper = path
                }

                StyledRect {
                    width: parent.width
                    height: extractionOptions.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.elevatedRowColor

                    Column {
                        id: extractionOptions
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS

                            StyledText {
                                text: I18n.tr("Light or Dark Result")
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            VgsDropdown {
                                width: parent.width
                                dropdownWidth: parent.width
                                currentValue: root.optionLabel(root.matugenModeOptions, SettingsData.matugenMode, I18n.tr("Match the image"))
                                options: root.matugenModeOptions.map(o => o.label)
                                onValueChanged: value => SettingsData.setMatugenMode(root.optionValue(root.matugenModeOptions, value, "auto"))
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingM

                            Column {
                                width: (parent.width - Theme.spacingM) / 2
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: I18n.tr("Color Style")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                VgsDropdown {
                                    width: parent.width
                                    dropdownWidth: parent.width
                                    currentValue: root.optionLabel(root.matugenSchemeOptions, SettingsData.matugenScheme, I18n.tr("Tonal Spot"))
                                    options: root.matugenSchemeOptions.map(o => o.label)
                                    onValueChanged: value => SettingsData.setMatugenScheme(root.optionValue(root.matugenSchemeOptions, value, "scheme-tonal-spot"))
                                }
                            }

                            Column {
                                width: (parent.width - Theme.spacingM) / 2
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: I18n.tr("Contrast")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                VgsDropdown {
                                    width: parent.width
                                    dropdownWidth: parent.width
                                    currentValue: root.optionLabel(root.matugenContrastOptions, SettingsData.matugenContrast, I18n.tr("Default (0)"))
                                    options: root.matugenContrastOptions.map(o => o.label)
                                    onValueChanged: value => SettingsData.setMatugenContrast(root.optionValue(root.matugenContrastOptions, value, 0))
                                }
                            }
                        }
                    }
                }

                Row {
                    spacing: Theme.spacingS
                    width: parent.width

                    VgsButton {
                        text: I18n.tr("Create & Apply")
                        enabled: root.selectedWallpaper !== "" && !root.selectedWallpaper.startsWith("#") && !VGSThemeService.busy
                        onClicked: VGSThemeService.setWallpaper(root.selectedWallpaper, true, SettingsData.matugenMode || "auto")
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Set Wallpaper Only")
                        enabled: root.selectedWallpaper !== "" && !VGSThemeService.busy
                        onClicked: VGSThemeService.setWallpaper(root.selectedWallpaper, false)
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Clear Wallpaper")
                        enabled: root.selectedWallpaper !== "" || SessionData.wallpaperPath !== ""
                        onClicked: {
                            root.selectedWallpaper = "";
                            VGSThemeService.clearWallpaper();
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Save Current Look")
                iconName: "save"
                settingKey: "vgsSaveCurrent"
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Keeps your current colors and wallpaper as a theme you can reapply anytime, with editable per-app files (saved under ~/.config/vshell/themes/).")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS
                    VgsTextField {
                        width: parent.width - saveButton.width - Theme.spacingS
                        text: root.saveName
                        placeholderText: I18n.tr("Theme name")
                        backgroundColor: Theme.surfaceContainerHighest
                        onTextChanged: root.saveName = text
                    }
                    VgsButton {
                        id: saveButton
                        text: I18n.tr("Save Theme")
                        enabled: root.saveName !== "" && !VGSThemeService.busy
                        onClicked: VGSThemeService.saveCurrent(root.saveName)
                    }
                }
            }
        }
    }
}
