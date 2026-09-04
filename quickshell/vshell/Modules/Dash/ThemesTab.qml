pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

// Theme browser for Dash. Apply uses the selection; the more button opens per-theme actions.
Item {
    id: root

    property bool active: false
    property var tabBarItem: null
    property var keyForwardTarget: null
    property var targetScreen: null
    property var parentPopout: null

    property string modeFilter: "all"
    property string searchQuery: ""
    readonly property var modeFilters: ["all", "dark", "light"]

    implicitWidth: SettingsData.showWeekNumber ? 736 : 700
    // Share the Dash tab height to avoid resizing during a tab switch. The grid scrolls within it.
    implicitHeight: 410

    // Sort favourites before the alphabetical remainder without changing order within either group.
    readonly property var filteredThemes: {
        const list = VGSThemeService.blueprints || [];
        const favorites = SettingsData.favoriteThemes || [];
        const query = searchQuery.trim().toLowerCase();
        return list.filter(bp => {
            if (modeFilter !== "all" && (bp.mode || "dark") !== modeFilter)
                return false;
            return !query || (bp.name || "").toLowerCase().includes(query);
        }).sort((a, b) => {
            const aFav = favorites.indexOf(a.name || "") >= 0;
            const bFav = favorites.indexOf(b.name || "") >= 0;
            if (aFav !== bFav)
                return aFav ? -1 : 1;
            return (a.name || "").localeCompare(b.name || "");
        });
    }

    // Focus the theme filter when Dash activates this tab.
    function focusSearch() {
        searchField.forceActiveFocus();
    }

    function onShown() {
        searchQuery = "";
        // Clear the field text explicitly: typing replaces its `text: searchQuery`
        // binding, so resetting searchQuery alone leaves the stale text visible.
        searchField.text = "";
        VGSThemeService.refresh();
        VGSThemeService.generateMissingPreviews();
        // Deferred so it runs after the dash's own open-focus handling settles.
        Qt.callLater(focusSearch);
    }

    // Forward search-field arrow keys to the theme selection without moving keyboard focus.
    Item {
        id: navRouter
        Keys.onPressed: event => {
            if (root.handleKeyEvent(event))
                event.accepted = true;
        }
    }

    onActiveChanged: {
        if (active)
            onShown();
    }

    // Loader creation can start with active already true. Refresh here because no active change signal then fires.
    Component.onCompleted: {
        if (active)
            onShown();
    }

    function handleKeyEvent(event) {
        if (event.key === Qt.Key_Down) {
            themeList.currentIndex = Math.min(themeList.currentIndex + 1, filteredThemes.length - 1);
            return true;
        }
        if (event.key === Qt.Key_Up) {
            themeList.currentIndex = Math.max(themeList.currentIndex - 1, 0);
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const entry = filteredThemes[themeList.currentIndex];
            if (entry && !VGSThemeService.busy)
                VGSThemeService.applyBlueprint(entry.name);
            return true;
        }
        return false;
    }

    Column {
        anchors.fill: parent

        anchors.topMargin: Theme.spacingM
        spacing: Theme.spacingM

        Row {
            width: parent.width
            spacing: Theme.spacingL

            VgsTextField {
                id: searchField
                width: parent.width - filterChips.width - wallpaperPolicyRow.width - parent.spacing * 2
                height: 34
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: I18n.tr("Search themes...")
                backgroundColor: Theme.surfaceContainerHighest
                leftIconName: "search"
                text: root.searchQuery
                onTextChanged: root.searchQuery = text

                ignoreUpDownKeys: true
                keyForwardTargets: [navRouter]
                onAccepted: {
                    const entry = root.filteredThemes[themeList.currentIndex];
                    if (entry && !VGSThemeService.busy)
                        VGSThemeService.applyBlueprint(entry.name);
                }
            }

            VgsFilterChips {
                id: filterChips
                width: 218
                anchors.verticalCenter: parent.verticalCenter
                chipHeight: 34
                showCounts: false
                model: [I18n.tr("All"), I18n.tr("Dark"), I18n.tr("Light")]
                currentIndex: root.modeFilters.indexOf(root.modeFilter)
                onSelectionChanged: index => root.modeFilter = root.modeFilters[index] || "all"
            }

            // Mirrors the wallpaper-source policy: off = themes only change
            // colors and the wallpaper stays put (Settings → Wallpaper).
            Row {
                id: wallpaperPolicyRow
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Use theme wallpapers")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                VgsToggle {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: SettingsData.wallpaperSource !== "folder"
                    onToggled: checked => SettingsData.set("wallpaperSource", checked ? "theme" : "folder")
                }
            }
        }

        VgsListView {
            id: themeList
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Theme.spacingS
            model: root.filteredThemes

            delegate: Rectangle {
                id: themeRow

                required property var modelData
                required property int index

                readonly property bool isCurrent: (VGSThemeService.currentTheme.name || "") === modelData.name
                readonly property bool isFavorite: SettingsData.isFavoriteTheme(modelData.name)
                readonly property bool isLight: (modelData.mode || "dark") === "light"
                readonly property bool isSelected: themeList.currentIndex === index
                property bool actionsOpen: false

                width: themeList.width
                height: 100 + (actionsOpen ? actionStrip.height + Theme.spacingS : 0)
                radius: Theme.cornerRadius
                color: isSelected ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                border.width: isCurrent ? 2 : 0
                border.color: Theme.primary

                Behavior on height {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.OutCubic
                    }
                }

                HoverHandler {
                    id: rowHover

                    onHoveredChanged: if (hovered)
                        themeList.currentIndex = themeRow.index
                }

                MouseArea {
                    id: rowArea
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 100
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!themeRow.isCurrent && !VGSThemeService.busy)
                            VGSThemeService.applyBlueprint(themeRow.modelData.name);
                    }
                }

                Row {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.spacingS
                    height: 100 - Theme.spacingS * 2
                    spacing: Theme.spacingM

                    Rectangle {
                        id: previewFrame
                        width: 152
                        height: parent.height
                        radius: Theme.cornerRadius - 2
                        color: themeRow.modelData.background || Theme.surfaceContainerHighest

                        Image {
                            anchors.fill: parent
                            visible: themeRow.modelData.preview !== ""
                            source: themeRow.modelData.preview ? "file://" + themeRow.modelData.preview : ""
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 320
                            asynchronous: true
                            cache: false
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: previewMask
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 1
                            }
                        }

                        Item {
                            id: previewMask
                            anchors.fill: parent
                            layer.enabled: true
                            layer.smooth: true
                            visible: false

                            Rectangle {
                                anchors.fill: parent
                                radius: previewFrame.radius
                                color: "black"
                                antialiasing: true
                            }
                        }


                        VgsSpinner {
                            anchors.centerIn: parent
                            size: 26
                            color: themeRow.modelData.foreground || Theme.primary
                            visible: themeRow.modelData.preview === "" && VGSThemeService.previewsGenerating
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: applyLabel.implicitWidth + Theme.spacingM * 2
                            height: 26
                            radius: 13
                            color: Qt.rgba(0, 0, 0, 0.55)
                            // Decorative only: the whole row is the click target.
                            visible: themeRow.isCurrent || themeRow.isSelected

                            StyledText {
                                id: applyLabel
                                anchors.centerIn: parent
                                text: themeRow.isCurrent ? I18n.tr("Active") : I18n.tr("Apply")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: "#ffffff"
                            }
                        }
                    }

                    Column {
                        width: parent.width - previewFrame.width - swatchRow.width - favoriteButton.width - moreButton.width - Theme.spacingM * 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        StyledText {
                            width: parent.width
                            text: themeRow.modelData.name || I18n.tr("unnamed")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        Row {
                            spacing: Theme.spacingXS

                            VgsIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: themeRow.isLight ? "light_mode" : "dark_mode"
                                size: 12
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: (themeRow.isLight ? I18n.tr("Light") : I18n.tr("Dark")) + (themeRow.modelData.builtin ? "" : " · " + I18n.tr("yours")) + (themeRow.modelData.pair ? " · ⇄ " + themeRow.modelData.pair : "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Row {
                        id: swatchRow
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        Repeater {
                            model: (themeRow.modelData.colors || []).slice(0, 6)

                            Rectangle {
                                required property string modelData
                                width: 14
                                height: 14
                                radius: 4
                                color: modelData
                                border.width: 1
                                border.color: Theme.outlineLight
                            }
                        }
                    }

                    VgsActionButton {
                        id: favoriteButton
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "star"
                        iconFilled: themeRow.isFavorite
                        iconColor: themeRow.isFavorite ? Theme.warning : Theme.surfaceVariantText
                        tooltipText: themeRow.isFavorite ? I18n.tr("Remove from favorites") : I18n.tr("Add to favorites")
                        onClicked: SettingsData.toggleFavoriteTheme(themeRow.modelData.name)
                    }

                    VgsActionButton {
                        id: moreButton
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: themeRow.actionsOpen ? "expand_less" : "more_horiz"
                        onClicked: themeRow.actionsOpen = !themeRow.actionsOpen
                    }
                }

                Flow {
                    id: actionStrip
                    visible: themeRow.actionsOpen
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingXS

                    VgsButton {
                        visible: !themeRow.isCurrent
                        height: 28
                        text: I18n.tr("Pair with current")
                        onClicked: {
                            const current = VGSThemeService.currentTheme.name || "";
                            if (!current || current === themeRow.modelData.name)
                                return;
                            VGSThemeService.setPair(current, themeRow.modelData.name);
                            VGSThemeService.setPair(themeRow.modelData.name, current);
                            themeRow.actionsOpen = false;
                        }
                    }

                    VgsButton {
                        height: 28
                        text: I18n.tr("New preview")
                        enabled: !VGSThemeService.previewsGenerating
                        onClicked: {
                            VGSThemeService.regeneratePreview(themeRow.modelData.name);
                            themeRow.actionsOpen = false;
                        }
                    }

                    VgsButton {
                        height: 28
                        text: I18n.tr("App theming")
                        onClicked: {
                            PopoutService.openSettingsWithTab("theme");
                            if (root.parentPopout)
                                root.parentPopout.dashVisible = false;
                        }
                    }

                    VgsButton {
                        height: 28
                        text: I18n.tr("Duplicate")
                        onClicked: {
                            VGSThemeService.duplicateTheme(themeRow.modelData.name);
                            themeRow.actionsOpen = false;
                        }
                    }

                    VgsButton {
                        visible: !themeRow.modelData.builtin
                        height: 28
                        text: I18n.tr("Delete")
                        onClicked: {
                            VGSThemeService.deleteTheme(themeRow.modelData.name);
                            themeRow.actionsOpen = false;
                        }
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: root.filteredThemes.length === 0

                VgsIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "palette"
                    size: 40
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.searchQuery ? I18n.tr("No themes match your search") : I18n.tr("No themes here yet")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                }
            }
        }
    }
}
