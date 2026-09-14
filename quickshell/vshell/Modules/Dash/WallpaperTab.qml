pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets

// Wallpaper browser for Dash, with per-wallpaper actions and monitor assignment.
Item {
    id: root

    property bool active: false
    property var tabBarItem: null
    property var keyForwardTarget: null
    property var targetScreen: null
    property var parentPopout: null

    // "theme" browses the applied theme's set; "all" the wallpaper folder and every installed theme.
    property string source: SettingsData.wallpaperSource === "folder" ? "all" : "theme"
    readonly property var sources: ["theme", "all"]
    readonly property string appliedTheme: (VGSThemeService.currentTheme || {}).name || ""
    readonly property string imageryCard: source === "theme" ? VGSThemeCatalogService.imageryCardFor(appliedTheme) : ""
    // Index of the tile whose "…" actions are open; -1 = none.
    property int actionsIndex: -1
    // True while navigating with arrow keys; draws the focus ring.
    property bool keyboardNav: false

    implicitWidth: SettingsData.showWeekNumber ? 736 : 700
    // Share the Dash tab height to avoid resizing during a tab switch. The grid scrolls within it.
    implicitHeight: 410

    readonly property var entries: source === "all" ? (VGSThemeService.allWallpapers || []) : (VGSThemeService.themeWallpapers || [])
    readonly property var actionsEntry: actionsIndex >= 0 && actionsIndex < (entries || []).length ? entries[actionsIndex] : null

    onActiveChanged: {
        if (active) {
            actionsIndex = -1;
            keyboardNav = false;
            refresh();
        }
    }

    onSourceChanged: {
        grid.currentIndex = -1;
        actionsIndex = -1;
        refresh();
    }

    function refresh() {
        if (source === "all") {
            VGSThemeService.refreshAllWallpapers();
            return;
        }
        VGSThemeService.refreshWallpapers();
        VGSThemeCatalogService.refresh();
    }

    // Start the imagery card's download or update, then close Dash as the full-screen switcher closes.
    function fetchImagery() {
        VGSThemeCatalogService.fetchImagery(appliedTheme, imageryCard);
        if (parentPopout)
            parentPopout.dashVisible = false;
    }

    function applyEntry(entry) {
        if (!entry || VGSThemeService.busy)
            return;
        // SessionData.setWallpaper propagates to all monitors under per-monitor mode.
        VGSThemeService.setWallpaper(entry.path);
    }

    function handleKeyEvent(event) {
        const count = (entries || []).length;
        if (count === 0)
            return false;
        const columns = grid.columns;
        if (event.key === Qt.Key_Right || event.key === Qt.Key_Left || event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            keyboardNav = true;
            if (event.key === Qt.Key_Right)
                grid.currentIndex = Math.min(grid.currentIndex + 1, count - 1);
            else if (event.key === Qt.Key_Left)
                grid.currentIndex = Math.max(grid.currentIndex - 1, 0);
            else if (event.key === Qt.Key_Down)
                grid.currentIndex = Math.min(grid.currentIndex < 0 ? 0 : grid.currentIndex + columns, count - 1);
            else
                grid.currentIndex = Math.max(grid.currentIndex - columns, 0);
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (keyboardNav && grid.currentIndex >= 0 && grid.currentIndex < count) {
                applyEntry(entries[grid.currentIndex]);
                return true;
            }
            return false;
        }
        if (event.key === Qt.Key_Escape && (keyboardNav || actionsIndex >= 0)) {
            keyboardNav = false;
            actionsIndex = -1;
            grid.currentIndex = -1;
            return true;
        }
        return false;
    }

    WallpaperThumbnailPreloader {
        id: thumbPreloader
        paths: (root.entries || []).map(e => e.path)
        cacheSize: 256
    }

    FileBrowserModal {
        id: addWallpaperBrowser
        browserTitle: I18n.tr("Add a wallpaper to this theme")
        browserType: "wallpaper"
        showHiddenFiles: true
        fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif"]
        onFileSelected: path => {
            VGSThemeService.wallpaperAdd(path);
            close();
        }
    }

    FileBrowserModal {
        id: folderPickBrowser
        browserTitle: I18n.tr("Pick any image inside your wallpaper folder")
        browserType: "wallpaper"
        showHiddenFiles: true
        fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif"]
        onFileSelected: path => {
            SettingsData.set("wallpaperFolder", path.substring(0, path.lastIndexOf("/")));
            close();
            VGSThemeService.refreshAllWallpapers();
        }
    }

    Column {
        anchors.fill: parent

        anchors.topMargin: Theme.spacingM
        spacing: Theme.spacingM

        Item {
            width: parent.width
            height: 36

            VgsFilterChips {
                id: sourceChips
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 230
                chipHeight: 28
                showCounts: false
                model: [I18n.tr("Theme"), I18n.tr("All")]
                currentIndex: root.sources.indexOf(root.source)
                onSelectionChanged: index => root.source = root.sources[index] || "theme"
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsButton {
                    height: 28
                    visible: root.source === "all"
                    iconName: "folder_open"
                    text: I18n.tr("Change folder")
                    onClicked: folderPickBrowser.open()
                }

                VgsButton {
                    height: 28
                    visible: root.imageryCard === "update" || root.imageryCard === "updating"
                    enabled: root.imageryCard === "update"
                    iconName: "download"
                    text: VGSThemeCatalogService.imageryCardLabel(root.appliedTheme, root.imageryCard)
                    onClicked: root.fetchImagery()
                }

                VgsButton {
                    height: 28
                    visible: root.source === "theme"
                    iconName: "add_photo_alternate"
                    text: I18n.tr("Add")
                    onClicked: addWallpaperBrowser.open()
                }
            }
        }

        // A failed theme read retains the previous paths. Label that set as retained rather than current.
        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.source === "theme" && VGSThemeService.wallpapersStaleNotice !== "" && (root.entries || []).length > 0
            text: VGSThemeService.wallpapersStaleNotice
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.warning
        }

        VgsGridView {
            id: grid

            readonly property int columns: 3

            width: parent.width
            height: parent.height - y - (actionBar.visible ? actionBar.height + Theme.spacingS : 0)
            clip: true
            model: root.entries
            currentIndex: -1
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.floor(cellWidth * 0.58)

            delegate: Item {
                id: tile

                required property var modelData
                required property int index

                readonly property bool isActiveWallpaper: {
                    if (modelData.path === SessionData.wallpaperPath)
                        return true;
                    if (SessionData.perMonitorWallpaper) {
                        const assigned = SessionData.monitorWallpapers || {};
                        for (const key in assigned) {
                            if (assigned[key] === modelData.path)
                                return true;
                        }
                    }
                    return false;
                }
                readonly property bool inTheme: root.source === "all" && VGSThemeService.inThemeSet(modelData, root.appliedTheme, VGSThemeService.themeWallpapers)
                readonly property bool actionsOpen: root.actionsIndex === index
                readonly property bool keyFocused: root.keyboardNav && grid.currentIndex === index
                readonly property real tileRadius: Theme.cornerRadius

                width: grid.cellWidth
                height: grid.cellHeight

                HoverHandler {
                    id: tileHover

                    onHoveredChanged: if (hovered) {
                        root.keyboardNav = false;
                        grid.currentIndex = tile.index;
                    }
                }

                Item {
                    id: card
                    anchors.fill: parent
                    anchors.margins: Theme.spacingXS

                    Rectangle {
                        anchors.fill: parent
                        radius: tile.tileRadius
                        color: Theme.surfaceContainer
                    }

                    CachingImage {
                        id: tileImage
                        anchors.fill: parent
                        imagePath: tile.modelData.path
                        maxCacheSize: 256
                        assumeCached: thumbPreloader.cacheReady
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: tileMask
                            maskThresholdMin: 0.5
                            maskSpreadAtMin: 1
                        }
                    }

                    Item {
                        id: tileMask
                        anchors.fill: parent
                        layer.enabled: true
                        layer.smooth: true
                        visible: false

                        Rectangle {
                            anchors.fill: parent
                            radius: tile.tileRadius
                            color: "black"
                            antialiasing: true
                        }
                    }

                    // A right-click opens the tile's actions, which carry Add to theme under All.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            root.keyboardNav = false;
                            if (mouse.button === Qt.RightButton)
                                root.actionsIndex = tile.index;
                            else
                                root.applyEntry(tile.modelData);
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.margins: Theme.spacingXS
                        width: sourceLabel.implicitWidth + Theme.spacingS * 2
                        height: 20
                        radius: 10
                        color: Qt.rgba(0, 0, 0, 0.55)
                        visible: root.source === "all"

                        StyledText {
                            id: sourceLabel
                            anchors.centerIn: parent
                            text: tile.modelData.source === "folder" ? I18n.tr("My folder") : (tile.modelData.source || "")
                            font.pixelSize: Theme.fontSizeSmall
                            color: "#ffffff"
                        }
                    }

                    VgsIcon {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: Theme.spacingXS
                        visible: tile.inTheme
                        name: "check_circle"
                        size: 18
                        color: Theme.primary
                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: Theme.spacingXS
                        width: 20
                        height: 20
                        radius: 10
                        color: Qt.rgba(0, 0, 0, 0.55)
                        visible: tile.modelData.default === true

                        VgsIcon {
                            anchors.centerIn: parent
                            name: "star"
                            size: 12
                            color: "#ffd54f"
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: tilePillLabel.implicitWidth + Theme.spacingM * 2
                        height: 26
                        radius: 13
                        color: Qt.rgba(0, 0, 0, 0.55)
                        // Decorative only: the whole tile is the click target.
                        visible: tileHover.hovered

                        StyledText {
                            id: tilePillLabel
                            anchors.centerIn: parent
                            text: tile.isActiveWallpaper ? I18n.tr("Active") : I18n.tr("Apply")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: "#ffffff"
                        }
                    }

                    VgsActionButton {
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: Theme.spacingXS
                        visible: tileHover.hovered || tile.actionsOpen
                        iconName: "more_horiz"
                        backgroundColor: Qt.rgba(0, 0, 0, 0.55)
                        iconColor: "#ffffff"
                        onClicked: {
                            root.keyboardNav = false;
                            root.actionsIndex = tile.actionsOpen ? -1 : tile.index;
                        }
                    }


                    Rectangle {
                        anchors.fill: parent
                        radius: tile.tileRadius
                        color: "transparent"
                        border.width: tile.isActiveWallpaper || tile.keyFocused || tile.actionsOpen ? 2 : 0
                        border.color: tile.isActiveWallpaper ? Theme.primary : (tile.keyFocused ? Theme.secondary : Theme.outline)
                        antialiasing: true
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: (root.entries || []).length === 0

                VgsIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "wallpaper"
                    size: 40
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // An empty set after a failed read means no retained fallback, not a successful read with no wallpapers.
                    text: {
                        if (root.source === "all")
                            return VGSThemeService.allWallpapersLoadFailed ? I18n.tr("Could not list wallpapers") + "\n" + VGSThemeService.allWallpapersLoadError : I18n.tr("No images in %1 or any installed theme").arg(Paths.shortenHome(VGSThemeService.wallpaperFolderPath));
                        if (VGSThemeService.wallpapersLoadFailed)
                            return I18n.tr("Could not read this theme's wallpapers") + (VGSThemeService.wallpapersLoadError ? "\n" + VGSThemeService.wallpapersLoadError : "");
                        return I18n.tr("This theme has no wallpapers yet");
                    }
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                }

                VgsButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.source === "all"
                    height: 30
                    text: I18n.tr("Choose folder")
                    onClicked: folderPickBrowser.open()
                }

                VgsButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.imageryCard === "download" || root.imageryCard === "downloading"
                    enabled: root.imageryCard === "download"
                    height: 30
                    iconName: "download"
                    text: VGSThemeCatalogService.imageryCardLabel(root.appliedTheme, root.imageryCard)
                    onClicked: root.fetchImagery()
                }
            }
        }

        Item {
            id: actionBar
            width: parent.width
            height: actionFlow.implicitHeight
            visible: root.actionsEntry !== null

            Flow {
                id: actionFlow
                width: parent.width
                spacing: Theme.spacingS

                VgsButton {
                    visible: root.source === "theme" && root.actionsEntry !== null && root.actionsEntry.default !== true
                    height: 28
                    variant: "secondary"
                    iconName: "star"
                    text: I18n.tr("Make default")
                    onClicked: {
                        VGSThemeService.wallpaperDefault(root.actionsEntry.file);
                        root.actionsIndex = -1;
                    }
                }

                VgsButton {
                    height: 28
                    variant: "secondary"
                    iconName: "light_mode"
                    text: I18n.tr("Light")
                    onClicked: SessionData.setModeWallpaper("light", root.actionsEntry.path)
                }

                VgsButton {
                    height: 28
                    variant: "secondary"
                    iconName: "dark_mode"
                    text: I18n.tr("Dark")
                    onClicked: SessionData.setModeWallpaper("dark", root.actionsEntry.path)
                }

                Repeater {
                    model: Quickshell.screens.length > 1 ? Quickshell.screens : []

                    VgsButton {
                        required property var modelData
                        height: 28
                        variant: "secondary"
                        iconName: "monitor"
                        text: modelData.name
                        onClicked: {
                            if (!SessionData.perMonitorWallpaper)
                                SessionData.setPerMonitorWallpaper(true);
                            SessionData.setMonitorWallpaper(modelData.name, root.actionsEntry.path);
                        }
                    }
                }

                VgsButton {
                    visible: root.source === "all" && root.actionsEntry !== null && !VGSThemeService.inThemeSet(root.actionsEntry, root.appliedTheme, VGSThemeService.themeWallpapers)
                    height: 28
                    variant: "secondary"
                    iconName: "add_photo_alternate"
                    text: I18n.tr("Add to theme")
                    onClicked: {
                        VGSThemeService.wallpaperAdd(root.actionsEntry.path);
                        root.actionsIndex = -1;
                    }
                }

                VgsButton {
                    height: 28
                    variant: "secondary"
                    iconName: "palette"
                    text: I18n.tr("Make a theme")
                    enabled: !VGSThemeService.busy
                    onClicked: {
                        VGSThemeService.setWallpaper(root.actionsEntry.path, true);
                        root.actionsIndex = -1;
                    }
                }

                VgsButton {
                    visible: root.source === "theme"
                    height: 28
                    variant: "secondary"
                    textColor: Theme.error
                    iconName: "delete"
                    text: I18n.tr("Remove")
                    onClicked: {
                        VGSThemeService.wallpaperRemove(root.actionsEntry.file);
                        root.actionsIndex = -1;
                    }
                }
            }
        }
    }
}
