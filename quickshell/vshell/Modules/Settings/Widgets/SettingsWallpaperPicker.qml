pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.FileBrowser
import qs.Widgets

Column {
    id: root

    property string path: ""
    property string fillMode: ""
    property string fallbackFillMode: "Fill"
    property string browserTitle: I18n.tr("Select background image")
    property string placeholderText: I18n.tr("Use desktop wallpaper")
    property string fillModeSettingKey: ""
    property var fillModeTags: []
    property bool showFillMode: true

    signal pathSelected(string path)
    signal fillModeSelected(string mode)

    readonly property var _fillModes: ["Stretch", "Fit", "Fill", "Tile", "TileVertically", "TileHorizontally", "Pad"]

    spacing: Theme.spacingS

    FileBrowserModal {
        id: wallpaperBrowserModal
        browserTitle: root.browserTitle
        browserType: "wallpaper"
        showHiddenFiles: true
        fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif"]
        onFileSelected: path => {
            root.pathSelected(path);
            close();
        }
    }

    Item {
        width: parent.width
        height: wallpaperPathField.height

        VgsTextField {
            id: wallpaperPathField
            width: parent.width
            rightAccessoryWidth: browseWallpaperButton.width + Theme.spacingM
            placeholderText: root.placeholderText
            text: root.path
            backgroundColor: Theme.popupSurfaceColor(Theme.surfaceContainerHighest)
            onTextChanged: {
                if (text !== root.path)
                    root.pathSelected(text);
            }
        }

        VgsButton {
            id: browseWallpaperButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            variant: "secondary"
            reserveTrailingSpacing: false
            text: I18n.tr("Browse")
            onClicked: wallpaperBrowserModal.open()
        }
    }

    SettingsDropdownRow {
        visible: root.showFillMode
        settingKey: root.fillModeSettingKey
        tags: root.fillModeTags
        text: I18n.tr("Wallpaper fill mode")
        description: I18n.tr("How the background image is scaled")
        options: root._fillModes.map(m => I18n.tr(m, "wallpaper fill mode"))
        currentValue: {
            var mode = (root.fillMode && root.fillMode !== "") ? root.fillMode : root.fallbackFillMode;
            var idx = root._fillModes.indexOf(mode);
            return idx >= 0 ? I18n.tr(root._fillModes[idx], "wallpaper fill mode") : I18n.tr("Fill", "wallpaper fill mode");
        }
        onValueChanged: value => {
            var idx = root._fillModes.map(m => I18n.tr(m, "wallpaper fill mode")).indexOf(value);
            if (idx >= 0)
                root.fillModeSelected(root._fillModes[idx]);
        }
    }
}
