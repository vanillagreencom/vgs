import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

// The Cloud Sync app: a standalone floating window in the same shape as the
// Settings app (sidebar + reading pane), because it is a settings-shaped
// product — accounts, folders, and the state of the syncing itself.
FloatingWindow {
    id: cloudSyncModal

    readonly property var log: Log.scoped("CloudSyncModal")

    property int currentSectionIndex: 0
    // Below this the sidebar takes the whole window and the menu button toggles
    // between navigation and content, the same master/detail behaviour the
    // Settings window uses.
    property bool isCompactMode: width < 720
    property bool menuVisible: !isCompactMode
    property bool shouldHaveFocus: visible
    property bool allowFocusOverride: false
    property alias shouldBeVisible: cloudSyncModal.visible

    readonly property var sections: [
        {
            "id": "accounts",
            "text": I18n.tr("Accounts", "Cloud Sync section: connected cloud accounts"),
            "icon": "account_circle"
        },
        {
            "id": "folders",
            "text": I18n.tr("Folders", "Cloud Sync section: synced folders"),
            "icon": "folder_open"
        },
        {
            "id": "activity",
            "text": I18n.tr("Activity", "Cloud Sync section: transfers and history"),
            "icon": "history"
        },
        {
            "id": "conflicts",
            "text": I18n.tr("Conflicts", "Cloud Sync section: files changed in both places"),
            "icon": "rule_folder"
        },
        {
            "id": "settings",
            "text": I18n.tr("Settings", "Cloud Sync section: global preferences"),
            "icon": "tune"
        }
    ]

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

    function resolveSectionIndex(name) {
        for (var i = 0; i < sections.length; i++) {
            if (sections[i].id === name)
                return i;
        }
        return -1;
    }

    function showWithSection(name) {
        const index = resolveSectionIndex(name);
        if (index >= 0)
            currentSectionIndex = index;
        visible = true;
    }

    function toggleMenu() {
        menuVisible = !menuVisible;
    }

    // ---- Cross-page navigation ----
    // Folders belong to accounts, so the Accounts page links into the Folders
    // page. Highlighting the target is what makes the jump legible: a page that
    // silently scrolls to a row looks like it did nothing.
    property string highlightFolderId: ""

    function showFolder(folderId) {
        highlightFolderId = folderId || "";
        currentSectionIndex = resolveSectionIndex("folders");
        if (isCompactMode)
            menuVisible = false;
        if (highlightFolderId.length > 0)
            highlightTimer.restart();
    }

    // The highlight is a pointer, not a selection: it fades once it has done
    // its job, so a card is not left permanently ringed.
    Timer {
        id: highlightTimer

        interval: 2600
        onTriggered: cloudSyncModal.highlightFolderId = ""
    }

    // ---- Dialog host ----
    // Flows live at window level rather than inside a page so they cover the
    // sidebar too and survive a section change underneath them.
    property var dialogArgs: ({})

    function openDialog(name, args) {
        dialogArgs = args || {};
        switch (name) {
        case "addAccount":
            dialogLoader.sourceComponent = addAccountDialog;
            break;
        case "addFolder":
            dialogLoader.sourceComponent = addFolderWizard;
            break;
        case "renameAccount":
            dialogLoader.sourceComponent = renameAccountDialog;
            break;
        case "reconnectAccount":
            dialogLoader.sourceComponent = reconnectAccountDialog;
            break;
        case "disconnectAccount":
            dialogLoader.sourceComponent = disconnectAccountDialog;
            break;
        case "folderOptions":
            dialogLoader.sourceComponent = folderOptionsDialog;
            break;
        case "resync":
            dialogLoader.sourceComponent = resyncDialog;
            break;
        default:
            cloudSyncModal.log.warn("Unknown Cloud Sync dialog:", name);
            return;
        }
    }

    function closeDialog() {
        dialogLoader.sourceComponent = null;
        dialogArgs = {};
    }

    objectName: "cloudSyncModal"
    title: I18n.tr("Cloud Sync", "Cloud Sync window title")
    minimumSize: Qt.size(520, 420)
    implicitWidth: 940
    implicitHeight: screen ? Math.min(880, screen.height - 100) : 880
    color: "transparent"
    visible: false

    onClosed: hide()

    onIsCompactModeChanged: {
        // Entering compact hides the menu rather than leaving it covering the
        // window: shrinking the window should reveal the content you were
        // reading, not a full-screen nav list.
        menuVisible = !isCompactMode;
    }

    onVisibleChanged: {
        if (!visible)
            closingModal();
    }

    // Holding a reference only while the window is open keeps the backend
    // subscription (and its progress polling) off when nobody is watching.
    Loader {
        active: cloudSyncModal.visible
        sourceComponent: Component {
            Ref {
                service: CloudSyncService
            }
        }
    }

    FocusScope {
        id: contentFocusScope

        LayoutMirroring.enabled: I18n.isRtl
        LayoutMirroring.childrenInherit: true

        anchors.fill: parent
        focus: true

        VgsFloatingSurface {
            id: surface

            anchors.fill: parent
            targetWindow: cloudSyncModal
            radius: Math.min(20, Theme.cornerRadius)
            windowActive: ToplevelManager.activeToplevel ? (ToplevelManager.activeToplevel.appId === "com.vanillagreen.vshell" && ToplevelManager.activeToplevel.title === cloudSyncModal.title) : true

            Item {
                anchors.fill: parent
                clip: true

                CloudSyncSidebar {
                    id: sidebar

                    anchors.left: parent.left
                    height: parent.height
                    width: cloudSyncModal.isCompactMode ? parent.width : implicitWidth
                    visible: cloudSyncModal.isCompactMode ? cloudSyncModal.menuVisible : true
                    sections: cloudSyncModal.sections
                    currentIndex: cloudSyncModal.currentSectionIndex
                    onSectionRequested: index => {
                        cloudSyncModal.currentSectionIndex = index;
                        if (cloudSyncModal.isCompactMode)
                            cloudSyncModal.menuVisible = false;
                    }
                }

                Item {
                    anchors.left: cloudSyncModal.isCompactMode ? (cloudSyncModal.menuVisible ? sidebar.right : parent.left) : sidebar.right
                    anchors.right: parent.right
                    height: parent.height
                    clip: true

                    // The reading pane stays near-opaque so file names and
                    // paths stay legible over any wallpaper.
                    Rectangle {
                        anchors.fill: parent
                        color: Theme.popupGlassEffect ? Theme.withAlpha(Theme.surfaceContainerLowest, 0.94) : "transparent"
                    }

                    CloudSyncContent {
                        id: content

                        anchors.fill: parent
                        parentModal: cloudSyncModal
                        currentIndex: cloudSyncModal.currentSectionIndex
                    }
                }
            }

            MouseArea {
                z: 20
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: cloudSyncModal.isCompactMode ? 48 : Theme.spacingM
                anchors.rightMargin: windowControls.canMaximize ? 88 : 48
                height: 42
                acceptedButtons: Qt.LeftButton
                onPressed: windowControls.tryStartMove()
                onDoubleClicked: windowControls.tryToggleMaximize()
            }

            Rectangle {
                id: compactMenuButton

                z: 35
                visible: cloudSyncModal.isCompactMode
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
                    tooltipText: I18n.tr("Menu", "Cloud Sync compact menu button tooltip")
                    onClicked: cloudSyncModal.toggleMenu()
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
                    name: cloudSyncModal.maximized ? "fullscreen_exit" : "fullscreen"
                    size: Theme.iconSize - 8
                    color: Theme.surfaceText
                }

                StateLayer {
                    stateColor: Theme.surfaceText
                    cornerRadius: maximizeButton.radius
                    tooltipText: cloudSyncModal.maximized ? I18n.tr("Restore", "Cloud Sync restore button tooltip") : I18n.tr("Maximize", "Cloud Sync maximize button tooltip")
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
                    tooltipText: I18n.tr("Close", "Cloud Sync close button tooltip")
                    onClicked: cloudSyncModal.hide()
                }
            }
        }

        Loader {
            id: dialogLoader

            anchors.fill: parent
            z: 100
            sourceComponent: null
        }
    }

    Component {
        id: addAccountDialog
        AddAccountDialog {
            parentModal: cloudSyncModal
        }
    }

    Component {
        id: addFolderWizard
        AddFolderWizard {
            parentModal: cloudSyncModal
            presetAccount: cloudSyncModal.dialogArgs.account || ""
        }
    }

    Component {
        id: renameAccountDialog
        RenameAccountDialog {
            parentModal: cloudSyncModal
            account: cloudSyncModal.dialogArgs.account || ""
        }
    }

    Component {
        id: reconnectAccountDialog
        ReconnectAccountDialog {
            parentModal: cloudSyncModal
            account: cloudSyncModal.dialogArgs.account || ""
        }
    }

    Component {
        id: disconnectAccountDialog
        DisconnectAccountDialog {
            parentModal: cloudSyncModal
            account: cloudSyncModal.dialogArgs.account || ""
        }
    }

    Component {
        id: folderOptionsDialog
        FolderOptionsDialog {
            parentModal: cloudSyncModal
            folderId: cloudSyncModal.dialogArgs.folderId || ""
        }
    }

    Component {
        id: resyncDialog
        ResyncDialog {
            parentModal: cloudSyncModal
            folderId: cloudSyncModal.dialogArgs.folderId || ""
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: cloudSyncModal
    }
}
