import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets

FloatingWindow {
    id: settingsModal

    property var profileBrowser: profileBrowserLoader.item
    property var wallpaperBrowser: wallpaperBrowserLoader.item

    function openProfileBrowser(allowStacking) {
        profileBrowserLoader.active = true;
        if (!profileBrowserLoader.item)
            return;
        if (allowStacking !== undefined)
            profileBrowserLoader.item.allowStacking = allowStacking;
        profileBrowserLoader.item.open();
    }

    function openWallpaperBrowser(allowStacking) {
        wallpaperBrowserLoader.active = true;
        if (!wallpaperBrowserLoader.item)
            return;
        if (allowStacking !== undefined)
            wallpaperBrowserLoader.item.allowStacking = allowStacking;
        wallpaperBrowserLoader.item.open();
    }
    property alias sidebar: sidebar
    property int currentTabIndex: 0
    property bool shouldHaveFocus: visible
    property bool allowFocusOverride: false
    property alias shouldBeVisible: settingsModal.visible
    property bool isCompactMode: width < 700
    property bool menuVisible: !isCompactMode
    property bool enableAnimations: true
    property string keybindSearchQuery: ""

    signal closingModal

    function show() {
        visible = true;
    }

    function hide() {
        visible = false;
    }

    function toggle() {
        visible = !visible;
    }

    function setTabIndex(tabIndex: int) {
        if (tabIndex < 0)
            return;
        currentTabIndex = tabIndex;
        sidebar.autoExpandForTab(tabIndex);
    }

    function showWithTab(tabIndex: int) {
        setTabIndex(tabIndex);
        visible = true;
    }

    function showWithTabName(tabName: string) {
        var idx = sidebar.resolveTabIndex(tabName);
        setTabIndex(idx);
        visible = true;
    }

    function resolveTabIndex(tabName: string): int {
        return sidebar.resolveTabIndex(tabName);
    }

    function showKeybindsSearch(query: string) {
        keybindSearchQuery = query || "";
        showWithTabName("keybinds");
    }

    function toggleMenu() {
        enableAnimations = true;
        menuVisible = !menuVisible;
    }

    objectName: "settingsModal"
    title: I18n.tr("Settings", "settings window title")
    minimumSize: Qt.size(500, 400)
    implicitWidth: 900
    implicitHeight: screen ? Math.min(940, screen.height - 100) : 940
    color: "transparent"
    visible: false

    onClosed: hide()

    onIsCompactModeChanged: {
        enableAnimations = false;
        if (!isCompactMode) {
            menuVisible = true;
        }
        Qt.callLater(() => {
            enableAnimations = true;
        });
    }

    onVisibleChanged: {
        if (!visible) {
            closingModal();
        } else {
            Qt.callLater(() => {
                sidebar.focusSearch();
            });
        }
    }

    Loader {
        active: settingsModal.visible
        sourceComponent: Component {
            Ref {
                service: CupsService
            }
        }
    }

    LazyLoader {
        id: profileBrowserLoader
        active: false

        FileBrowserModal {
            id: profileBrowserItem

            allowStacking: true
            parentModal: settingsModal
            browserTitle: I18n.tr("Select Profile Image", "profile image file browser title")
            browserType: "profile"
            showHiddenFiles: true
            fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif", "*.exr"]
            onFileSelected: path => {
                PortalService.setProfileImage(path);
                close();
            }
            onDialogClosed: () => {
                allowStacking = true;
            }
        }
    }

    LazyLoader {
        id: wallpaperBrowserLoader
        active: false

        FileBrowserModal {
            id: wallpaperBrowserItem

            allowStacking: true
            parentModal: settingsModal
            browserTitle: I18n.tr("Select Wallpaper", "wallpaper file browser title")
            browserType: "wallpaper"
            showHiddenFiles: true
            fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif", "*.exr"]
            onFileSelected: path => {
                SessionData.setWallpaper(path);
                close();
            }
            onDialogClosed: () => {
                allowStacking = true;
            }
        }
    }

    FocusScope {
        id: contentFocusScope

        property bool disablePopupTransparency: false

        LayoutMirroring.enabled: I18n.isRtl
        LayoutMirroring.childrenInherit: true

        anchors.fill: parent
        focus: true

        VgsFloatingSurface {
            id: settingsSurface

            anchors.fill: parent
            targetWindow: settingsModal
            radius: Math.min(20, Theme.cornerRadius)
            // Border follows compositor focus so the window reads active/inactive
            // exactly like a native Hyprland window (accent when focused, outline
            // when not).
            windowActive: ToplevelManager.activeToplevel ? (ToplevelManager.activeToplevel.appId === "com.vanillagreen.vshell" && ToplevelManager.activeToplevel.title === settingsModal.title) : true

            Column {
                anchors.fill: parent
                spacing: 0

            Rectangle {
                id: readOnlyBanner

                property bool showBanner: (SettingsData._isReadOnly && SettingsData._hasUnsavedChanges) || (SessionData._isReadOnly && SessionData._hasUnsavedChanges)

                width: parent.width
                height: showBanner ? bannerContent.implicitHeight + Theme.spacingM * 2 : 0
                color: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
                visible: showBanner
                clip: true

                Behavior on height {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                Row {
                    id: bannerContent

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: settingsModal.isCompactMode ? (Theme.spacingL + 32) : Theme.spacingL
                    anchors.rightMargin: Theme.spacingM + 32
                    spacing: Theme.spacingM

                    VgsIcon {
                        name: "info"
                        size: Theme.iconSize
                        color: Theme.warning
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        id: bannerText

                        text: I18n.tr("Settings are read-only. Changes will not persist.", "read-only settings warning for NixOS home-manager users")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(100, parent.width - (copySettingsButton.visible ? copySettingsButton.width + Theme.spacingM : 0) - (copySessionButton.visible ? copySessionButton.width + Theme.spacingM : 0) - Theme.spacingM * 2 - Theme.iconSize)
                        wrapMode: Text.WordWrap
                    }

                    VgsButton {
                        id: copySettingsButton

                        visible: SettingsData._isReadOnly && SettingsData._hasUnsavedChanges
                        text: "settings.json"
                        iconName: "content_copy"
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        buttonHeight: 32
                        horizontalPadding: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            Quickshell.execDetached([Paths.vshellCli, "cl", "copy", SettingsData.getCurrentSettingsJson()]);
                            ToastService.showInfo(I18n.tr("Copied to clipboard"));
                        }
                    }

                    VgsButton {
                        id: copySessionButton

                        visible: SessionData._isReadOnly && SessionData._hasUnsavedChanges
                        text: "session.json"
                        iconName: "content_copy"
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        buttonHeight: 32
                        horizontalPadding: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                            Quickshell.execDetached([Paths.vshellCli, "cl", "copy", SessionData.getCurrentSessionJson()]);
                            ToastService.showInfo(I18n.tr("Copied to clipboard"));
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: parent.height - readOnlyBanner.height
                clip: true

                SettingsSidebar {
                    id: sidebar

                    anchors.left: parent.left
                    width: settingsModal.isCompactMode ? parent.width : sidebar.implicitWidth
                    visible: settingsModal.isCompactMode ? settingsModal.menuVisible : true
                    parentModal: settingsModal
                    currentIndex: settingsModal.currentTabIndex
                    onTabChangeRequested: tabIndex => {
                        settingsModal.currentTabIndex = tabIndex;
                        if (settingsModal.isCompactMode) {
                            settingsModal.enableAnimations = true;
                            settingsModal.menuVisible = false;
                        }
                    }
                }

                Item {
                    anchors.left: settingsModal.isCompactMode ? (settingsModal.menuVisible ? sidebar.right : parent.left) : sidebar.right
                    anchors.right: parent.right
                    height: parent.height
                    clip: true

                    // macOS-style glass layering: the sidebar chrome carries the
                    // glass; the reading pane stays near-opaque so settings text
                    // is legible over any wallpaper.
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.popupGlassEffect ? Theme.withAlpha(Theme.surfaceContainerLowest, 0.94) : "transparent"
                    }

                    SettingsContent {
                        id: content

                        anchors.fill: parent
                        parentModal: settingsModal
                        currentIndex: settingsModal.currentTabIndex
                    }
                }
            }
            }

            MouseArea {
                z: 20
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: settingsModal.isCompactMode ? 48 : Theme.spacingM
                anchors.rightMargin: windowControls.canMaximize ? 88 : 48
                height: 42
                acceptedButtons: Qt.LeftButton
                onPressed: windowControls.tryStartMove()
                onDoubleClicked: windowControls.tryToggleMaximize()
            }

        Rectangle {
            id: compactMenuButton

            z: 35
            visible: settingsModal.isCompactMode
            width: 28
            height: 28
            radius: width / 2
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingM
            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupGlassEffect ? 0.34 : 0.58)
            border.color: Theme.withAlpha(Theme.outline, Theme.popupGlassEffect ? 0.16 : 0.10)
            border.width: 1
            antialiasing: true

            VgsIcon {
                anchors.centerIn: parent
                name: "menu"
                size: Theme.iconSize - 6
                color: Theme.surfaceText
            }

            StateLayer {
                stateColor: Theme.surfaceText
                cornerRadius: compactMenuButton.radius
                tooltipText: I18n.tr("Menu", "settings compact menu button tooltip")
                onClicked: settingsModal.toggleMenu()
            }
        }

        Rectangle {
            id: maximizeButton

            z: 35
            visible: windowControls.canMaximize
            width: 28
            height: 28
            radius: width / 2
            anchors.right: closeButton.left
            anchors.rightMargin: Theme.spacingXS
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingM
            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupGlassEffect ? 0.34 : 0.58)
            border.color: Theme.withAlpha(Theme.outline, Theme.popupGlassEffect ? 0.16 : 0.10)
            border.width: 1
            antialiasing: true

            VgsIcon {
                anchors.centerIn: parent
                name: settingsModal.maximized ? "fullscreen_exit" : "fullscreen"
                size: Theme.iconSize - 8
                color: Theme.surfaceText
            }

            StateLayer {
                stateColor: Theme.surfaceText
                cornerRadius: maximizeButton.radius
                tooltipText: settingsModal.maximized ? I18n.tr("Restore", "settings restore button tooltip") : I18n.tr("Maximize", "settings maximize button tooltip")
                onClicked: windowControls.tryToggleMaximize()
            }
        }

        Rectangle {
            id: closeButton

            z: 35
            width: 28
            height: 28
            radius: width / 2
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.top: parent.top
            anchors.topMargin: Theme.spacingM
            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupGlassEffect ? 0.34 : 0.58)
            border.color: Theme.withAlpha(Theme.outline, Theme.popupGlassEffect ? 0.16 : 0.10)
            border.width: 1
            antialiasing: true

            VgsIcon {
                anchors.centerIn: parent
                name: "close"
                size: Theme.iconSize - 6
                color: Theme.surfaceText
            }

            StateLayer {
                stateColor: Theme.surfaceText
                cornerRadius: closeButton.radius
                tooltipText: I18n.tr("Close", "settings close button tooltip")
                onClicked: settingsModal.hide()
            }
        }
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: settingsModal
    }
}
