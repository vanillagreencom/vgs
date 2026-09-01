pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root
    property var parentModal: null

    readonly property var timeoutOptions: [I18n.tr("15 seconds"), I18n.tr("30 seconds"), I18n.tr("1 minute"), I18n.tr("2 minutes"), I18n.tr("3 minutes"), I18n.tr("4 minutes"), I18n.tr("5 minutes"), I18n.tr("10 minutes"), I18n.tr("15 minutes"), I18n.tr("30 minutes")]
    readonly property var timeoutValues: [15, 30, 60, 120, 180, 240, 300, 600, 900, 1800]

    function getTimeoutIndex(timeout) {
        var idx = timeoutValues.indexOf(timeout);
        return idx >= 0 ? idx : timeoutValues.indexOf(240);
    }

    FileBrowserModal {
        id: screensaverVideoBrowserModal
        browserTitle: I18n.tr("Select Screensaver Video")
        browserType: "video"
        showHiddenFiles: false
        fileExtensions: ["*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.m4v"]
        onFileSelected: path => SettingsData.set("screensaverVideoPath", path)
    }

    FileBrowserModal {
        id: screensaverImageBrowserModal
        browserTitle: I18n.tr("Select Screensaver Picture")
        browserType: "wallpaper"
        showHiddenFiles: false
        fileExtensions: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.svg"]
        onFileSelected: path => {
            SettingsData.set("screensaverAsciiImagePath", path);
            ScreensaverService.regenerateAscii();
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
                activeId: "screensaver"
            }

            SettingsCard {
                title: I18n.tr("Screensaver")
                iconName: "screenshot_monitor"
                settingKey: "screensaver"
                tags: ["screensaver", "saver", "ascii", "video", "idle", "tte", "art"]
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("A decorative screensaver shown after idle, before the lock and monitor-off stages. Any key or mouse movement dismisses it; locking always replaces it.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                SettingsToggleRow {
                    settingKey: "screensaverEnabled"
                    text: I18n.tr("Screensaver")
                    description: I18n.tr("Start the screensaver when the session goes idle")
                    checked: SettingsData.screensaverEnabled
                    onToggled: checked => SettingsData.set("screensaverEnabled", checked)
                }

                SettingsDropdownRow {
                    id: timeoutDropdown
                    settingKey: "screensaverTimeout"
                    text: I18n.tr("Start After")
                    options: root.timeoutOptions
                    visible: SettingsData.screensaverEnabled
                    Component.onCompleted: currentValue = root.timeoutOptions[root.getTimeoutIndex(SettingsData.screensaverTimeout)]
                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index >= 0)
                            SettingsData.set("screensaverTimeout", root.timeoutValues[index]);
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Screensaver Content")
                iconName: "image"
                settingKey: "screensaverContent"
                width: parent.width
                visible: SettingsData.screensaverEnabled

                SettingsChoiceRow {
                    text: I18n.tr("Screensaver Type")
                    model: [I18n.tr("ASCII Art"), I18n.tr("Video")]
                    currentIndex: SettingsData.screensaverType === "video" ? 1 : 0
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            SettingsData.set("screensaverType", index === 1 ? "video" : "ascii");
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: SettingsData.screensaverType === "ascii"

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: I18n.tr("Converts a picture into animated braille art. Leave empty to use the built-in VGS logo.")
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    StyledText {
                        width: parent.width
                        visible: ScreensaverService.lastError !== "" && SettingsData.screensaverAsciiImagePath !== ""
                        wrapMode: Text.WordWrap
                        // Converting needs ImageMagick, which VGS does not require.
                        // Without this the field just keeps showing the picture that
                        // was silently never rendered.
                        text: I18n.tr("Could not convert this picture — the screensaver keeps its previous art. %1").arg(ScreensaverService.lastError)
                        color: Theme.warning
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Item {
                        width: parent.width
                        height: asciiImagePathField.height

                        VgsTextField {
                            id: asciiImagePathField
                            width: parent.width
                            rightAccessoryWidth: browseAsciiBtn.width + Theme.spacingM
                            placeholderText: I18n.tr("Built-in VGS logo")
                            text: SettingsData.screensaverAsciiImagePath
                            backgroundColor: Theme.surfaceContainerHighest
                            onTextChanged: {
                                if (text !== SettingsData.screensaverAsciiImagePath)
                                    SettingsData.set("screensaverAsciiImagePath", text);
                            }
                        }

                        VgsButton {
                            id: browseAsciiBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            variant: "secondary"
                            text: I18n.tr("Browse")
                            onClicked: screensaverImageBrowserModal.open()
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: SettingsData.screensaverType === "video"

                    StyledText {
                        width: parent.width
                        visible: !MultimediaService.available
                        wrapMode: Text.WordWrap
                        text: I18n.tr("QtMultimedia is not available — the video screensaver requires Qt Multimedia")
                        color: Theme.warning
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Item {
                        width: parent.width
                        height: videoPathField.height

                        VgsTextField {
                            id: videoPathField
                            width: parent.width
                            rightAccessoryWidth: browseVideoBtn.width + Theme.spacingM
                            placeholderText: I18n.tr("/path/to/video.mp4")
                            text: SettingsData.screensaverVideoPath
                            backgroundColor: Theme.surfaceContainerHighest
                            onTextChanged: {
                                if (text !== SettingsData.screensaverVideoPath)
                                    SettingsData.set("screensaverVideoPath", text);
                            }
                        }

                        VgsButton {
                            id: browseVideoBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            variant: "secondary"
                            text: I18n.tr("Browse")
                            onClicked: screensaverVideoBrowserModal.open()
                        }
                    }
                }

                VgsButton {
                    variant: "secondary"
                    text: ScreensaverService.generating ? I18n.tr("Preparing…") : I18n.tr("Preview Screensaver")
                    enabled: !ScreensaverService.generating
                    onClicked: ScreensaverService.start()
                }
            }
        }
    }
}
