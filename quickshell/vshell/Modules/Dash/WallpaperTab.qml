pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets

// Wallpapers tab of the dash: thumbnail grid over the current theme's wallpaper
// set or the user's own folder. Click a wallpaper to apply it; the tile's "…"
// button opens per-wallpaper actions (default, light/dark, monitors, remove).
Item {
    id: root

    property bool active: false
    property var tabBarItem: null
    property var keyForwardTarget: null
    property var targetScreen: null
    property var parentPopout: null

    property string source: SettingsData.wallpaperSource === "folder" ? "folder" : "theme"
    readonly property var sources: ["theme", "folder"]
    property var folderEntries: []
    // Index of the tile whose "…" actions are open; -1 = none.
    property int actionsIndex: -1
    // True while navigating with arrow keys; draws the focus ring.
    property bool keyboardNav: false

    implicitWidth: SettingsData.showWeekNumber ? 736 : 700
    // Match the shared dash tab height (overview/media/weather = 410) so switching
    // tabs never resizes the popout — a height change on switch caused a shrink-only
    // flash. The wallpaper grid fills and scrolls within whatever height it's given.
    implicitHeight: 410

    readonly property string effectiveFolder: {
        const configured = (SettingsData.wallpaperFolder || "").trim();
        if (configured)
            return configured.startsWith("~") ? Paths.strip(Paths.home) + configured.substring(1) : configured;
        return Paths.strip(Paths.home) + "/Pictures/Wallpapers";
    }

    readonly property var entries: source === "folder" ? folderEntries : (VGSThemeService.themeWallpapers || [])
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
        if (source === "folder")
            listFolder();
        else
            VGSThemeService.refreshWallpapers();
    }

    function listFolder() {
        const dir = effectiveFolder;
        Proc.runCommand("wallpaperFolderScan", ["sh", "-c", `find -L "$1" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.bmp" -o -iname "*.gif" -o -iname "*.webp" -o -iname "*.jxl" -o -iname "*.avif" -o -iname "*.heif" \\) 2>/dev/null | sort`, "scan", dir], function(output, code) {
            const files = (output || "").trim().split("\n").filter(f => f.length > 0);
            root.folderEntries = files.map(path => ({
                file: path.substring(path.lastIndexOf("/") + 1),
                path: path,
                origin: "folder",
                default: false
            }));
        });
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
            root.listFolder();
        }
    }

    Column {
        anchors.fill: parent
        // Same header rhythm as the themes tab: air between the tab bar, the
        // filter row, and the grid below.
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
                model: [I18n.tr("Theme set"), I18n.tr("My folder")]
                currentIndex: root.sources.indexOf(root.source)
                onSelectionChanged: index => root.source = root.sources[index] || "theme"
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsButton {
                    height: 28
                    visible: root.source === "folder"
                    iconName: "folder_open"
                    text: I18n.tr("Change folder")
                    onClicked: folderPickBrowser.open()
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
                readonly property bool actionsOpen: root.actionsIndex === index
                readonly property bool keyFocused: root.keyboardNav && grid.currentIndex === index
                readonly property real tileRadius: Theme.cornerRadius

                width: grid.cellWidth
                height: grid.cellHeight

                HoverHandler {
                    id: tileHover
                    // Mouse hover takes focus back from the keyboard so only one tile
                    // is highlighted at a time; arrow keys then resume from this tile.
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

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.keyboardNav = false;
                            root.applyEntry(tile.modelData);
                        }
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

                    // Border overlay above the image so edges stay clean.
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
                    text: root.source === "folder" ? I18n.tr("No images in ") + Paths.shortenHome(root.effectiveFolder) : I18n.tr("This theme has no wallpapers yet")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                }

                VgsButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.source === "folder"
                    height: 30
                    text: I18n.tr("Choose folder")
                    onClicked: folderPickBrowser.open()
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
                    visible: root.source === "folder"
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
                    outlineColor: Theme.withAlpha(Theme.error, 0.45)
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
