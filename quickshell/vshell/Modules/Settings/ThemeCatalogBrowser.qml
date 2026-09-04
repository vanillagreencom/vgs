pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

// Browse downloadable themes. The helper verifies catalog downloads before installation.
FloatingWindow {
    id: root

    property var parentModal: null
    parentWindow: parentModal
    property string searchQuery: ""
    property string modeFilter: "all"
    property string installFilter: "all"
    readonly property var modeFilters: ["all", "dark", "light"]
    readonly property var installFilters: ["all", "available", "installed"]

    readonly property var filteredEntries: {
        const query = searchQuery.trim().toLowerCase();
        return (VGSThemeCatalogService.entries || []).filter(entry => {
            if (modeFilter !== "all" && (entry.mode || "dark") !== modeFilter)
                return false;
            if (installFilter === "available" && entry.installed)
                return false;
            if (installFilter === "installed" && !entry.installed)
                return false;
            return !query || (entry.name || "").toLowerCase().includes(query);
        });
    }

    // Encode screenshot paths as URLs so spaces and # in directory names remain part of the path.
    function imageUrl(path) {
        if (!path)
            return "";
        if (path.startsWith("file://"))
            return path;
        return "file://" + path.split('/').map(s => encodeURIComponent(s)).join('/');
    }

    function show() {
        if (parentModal)
            parentModal.shouldHaveFocus = false;
        visible = true;
        Qt.callLater(() => searchField.forceActiveFocus());
    }

    function hide() {
        visible = false;
        if (!parentModal)
            return;
        parentModal.shouldHaveFocus = Qt.binding(() => parentModal.shouldBeVisible);
        Qt.callLater(() => {
            if (parentModal.modalFocusScope)
                parentModal.modalFocusScope.forceActiveFocus();
        });
    }

    objectName: "themeCatalogBrowser"
    title: I18n.tr("Download Themes")
    minimumSize: Qt.size(560, 420)
    implicitWidth: 880
    implicitHeight: 680
    color: "transparent"
    visible: false

    onClosed: hide()

    onVisibleChanged: {
        if (visible) {
            VGSThemeCatalogService.refresh();
            return;
        }
        searchQuery = "";
        searchField.text = "";
    }

    // Ask before removal because the theme directory can contain user edits.
    function confirmRemove(name) {
        removeConfirm.showWithOptions({
            "title": I18n.tr("Remove Theme"),
            "message": I18n.tr("Delete the downloaded theme '%1'? Any changes you made to it are deleted too. You can download it again later.").arg(name),
            "confirmText": I18n.tr("Remove"),
            "cancelText": I18n.tr("Cancel"),
            "confirmColor": Theme.error,
            "onConfirm": () => VGSThemeCatalogService.remove(name)
        });
    }

    ConfirmModal {
        id: removeConfirm
    }

    Connections {
        target: VGSThemeCatalogService
        function onOperationCompleted(success, message) {
            if (success)
                ToastService.showInfo(message);
            else
                ToastService.showError(I18n.tr("Theme download"), message);
        }
    }

    VgsFloatingSurface {
        anchors.fill: parent
        targetWindow: root

        FocusScope {
            id: keyHandler
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.hide();
                    event.accepted = true;
                }
            }

            Item {
                anchors.fill: parent
                anchors.margins: Theme.spacingL

                Item {
                    id: headerArea
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.max(headerIcon.height, headerText.height, closeButton.height)

                    MouseArea {
                        anchors.fill: parent
                        onPressed: windowControls.tryStartMove()
                        onDoubleClicked: windowControls.tryToggleMaximize()
                    }

                    VgsIcon {
                        id: headerIcon
                        name: "cloud_download"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        id: headerText
                        text: I18n.tr("Download Themes")
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        anchors.left: headerIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        VgsButton {
                            id: downloadAllButton
                            variant: "secondary"
                            height: 28
                            iconName: "download"
                            enabled: !VGSThemeCatalogService.busy && VGSThemeCatalogService.downloadableCount > 0
                            text: VGSThemeCatalogService.downloadingAll
                                  ? I18n.tr("Downloading…")
                                  : I18n.tr("Download All (%1)").arg(VGSThemeCatalogService.formatSize(VGSThemeCatalogService.downloadableSize))
                            onClicked: VGSThemeCatalogService.installAll()
                        }

                        VgsActionButton {
                            iconName: "refresh"
                            iconSize: 18
                            iconColor: Theme.primary
                            visible: !VGSThemeCatalogService.loading
                            onClicked: VGSThemeCatalogService.refresh()
                        }

                        VgsActionButton {
                            visible: windowControls.canMaximize
                            iconName: root.maximized ? "fullscreen_exit" : "fullscreen"
                            iconSize: Theme.iconSize - 2
                            iconColor: Theme.outline
                            onClicked: windowControls.tryToggleMaximize()
                        }

                        VgsActionButton {
                            id: closeButton
                            iconName: "close"
                            iconSize: Theme.iconSize - 2
                            iconColor: Theme.outline
                            onClicked: root.hide()
                        }
                    }
                }

                StyledText {
                    id: descriptionText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: headerArea.bottom
                    anchors.topMargin: Theme.spacingM
                    text: VGSThemeCatalogService.available
                          ? I18n.tr("%1 themes · %2 installed · downloads land in ~/.config/vshell/themes")
                            .arg(VGSThemeCatalogService.entries.length)
                            .arg(VGSThemeCatalogService.installedCount)
                          : I18n.tr("No theme catalog found in this install.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                    wrapMode: Text.WordWrap
                }

                // Keep search on its own line and wrap chips so narrow windows retain usable input width.
                Column {
                    id: filterRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: descriptionText.bottom
                    anchors.topMargin: Theme.spacingM
                    spacing: Theme.spacingS

                    VgsTextField {
                        id: searchField
                        width: parent.width
                        height: 36
                        placeholderText: I18n.tr("Search themes...")
                        backgroundColor: Theme.surfaceContainerHigh
                        leftIconName: "search"
                        text: root.searchQuery
                        onTextChanged: root.searchQuery = text
                        keyForwardTargets: [keyHandler]
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsFilterChips {
                            id: installChips
                            width: 250
                            chipHeight: 36
                            showCounts: false
                            model: [I18n.tr("All"), I18n.tr("Not installed"), I18n.tr("Installed")]
                            currentIndex: root.installFilters.indexOf(root.installFilter)
                            onSelectionChanged: index => root.installFilter = root.installFilters[index] || "all"
                        }

                        VgsFilterChips {
                            id: modeChips
                            width: 190
                            chipHeight: 36
                            showCounts: false
                            model: [I18n.tr("All"), I18n.tr("Dark"), I18n.tr("Light")]
                            currentIndex: root.modeFilters.indexOf(root.modeFilter)
                            onSelectionChanged: index => root.modeFilter = root.modeFilters[index] || "all"
                        }
                    }
                }

                VgsGridView {
                    id: grid
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: filterRow.bottom
                    anchors.topMargin: Theme.spacingM
                    anchors.bottom: parent.bottom
                    clip: true
                    visible: root.filteredEntries.length > 0

                    readonly property int cardInset: Theme.spacingXS * 2 + Theme.spacingS * 2
                    // Everything under the preview: name row, swatches, button,
                    // plus the column's gaps and the card's own margins.
                    readonly property int cardControls: 22 + 10 + 30 + Theme.spacingS * 5 + Theme.spacingXS * 2
                    cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 260)))
                    // Derive cell height from the preview aspect ratio so rows do not overlap when column count changes.
                    cellHeight: Math.round((cellWidth - cardInset) * 9 / 16) + cardControls
                    model: root.filteredEntries

                    delegate: Item {
                        id: cell
                        required property var modelData

                        readonly property bool pending: VGSThemeCatalogService.isPending(modelData.name)
                            || VGSThemeCatalogService.downloadingAll && !modelData.installed
                        readonly property bool removable: modelData.downloaded === true

                        width: grid.cellWidth
                        height: grid.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingXS
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer
                            border.width: 1
                            border.color: Theme.borderColor

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Rectangle {
                                    id: previewFrame
                                    width: parent.width
                                    height: Math.round(width * 9 / 16)
                                    radius: Theme.cornerRadius - 2
                                    clip: true
                                    color: cell.modelData.background || Theme.surfaceContainerHighest

                                    Image {
                                        anchors.fill: parent
                                        visible: (cell.modelData.preview || "") !== ""
                                        source: root.imageUrl(cell.modelData.preview)
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: 480
                                        asynchronous: true
                                        cache: false
                                    }

                                    StyledText {
                                        anchors.centerIn: parent
                                        visible: (cell.modelData.preview || "") === ""
                                        text: I18n.tr("No screenshot")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: cell.modelData.foreground || Theme.surfaceVariantText
                                    }

                                    Rectangle {
                                        anchors.top: parent.top
                                        anchors.right: parent.right
                                        anchors.margins: Theme.spacingXS
                                        visible: cell.modelData.installed === true
                                        width: installedLabel.implicitWidth + Theme.spacingS * 2
                                        height: 20
                                        radius: 10

                                        color: Theme.surfaceContainer
                                        border.width: 1
                                        border.color: Theme.borderColor

                                        StyledText {
                                            id: installedLabel
                                            anchors.centerIn: parent
                                            text: cell.modelData.builtin ? I18n.tr("Included") : I18n.tr("Installed")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceText
                                        }
                                    }

                                    VgsSpinner {
                                        anchors.centerIn: parent
                                        size: 26
                                        visible: cell.pending
                                        running: cell.pending
                                        color: cell.modelData.foreground || Theme.primary
                                    }
                                }

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        width: parent.width - sizeLabel.implicitWidth - Theme.spacingXS
                                        text: cell.modelData.name || ""
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        id: sizeLabel
                                        text: VGSThemeCatalogService.formatSize(cell.modelData.size)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                Row {
                                    width: parent.width
                                    spacing: 3

                                    Repeater {
                                        model: (cell.modelData.colors || []).slice(0, 8)

                                        Rectangle {
                                            required property var modelData
                                            width: (cell.width - grid.cardInset - 3 * 7) / 8
                                            height: 10
                                            radius: 3
                                            color: modelData
                                        }
                                    }
                                }

                                VgsButton {
                                    width: parent.width
                                    height: 30
                                    variant: cell.modelData.installed ? "secondary" : "primary"
                                    enabled: !cell.pending && (!cell.modelData.installed || cell.removable)
                                    iconName: cell.modelData.installed ? (cell.removable ? "delete" : "check") : "download"
                                    // "Included" means the package shipped it; a
                                    // hand-made user theme of the same name is
                                    // "Installed" and equally not removable here.
                                    text: {
                                        if (!cell.modelData.installed)
                                            return I18n.tr("Download");
                                        if (cell.removable)
                                            return I18n.tr("Remove");
                                        return cell.modelData.builtin ? I18n.tr("Included") : I18n.tr("Installed");
                                    }
                                    onClicked: {
                                        if (!cell.modelData.installed)
                                            VGSThemeCatalogService.install(cell.modelData.name);
                                        else if (cell.removable)
                                            root.confirmRemove(cell.modelData.name);
                                    }
                                }
                            }
                        }
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingM
                    visible: root.filteredEntries.length === 0

                    VgsSpinner {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: 28
                        visible: VGSThemeCatalogService.loading
                        running: VGSThemeCatalogService.loading
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !VGSThemeCatalogService.loading
                        width: Math.min(implicitWidth, root.width - Theme.spacingL * 4)
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: {
                            if (VGSThemeCatalogService.available)
                                return I18n.tr("No themes match this filter");
                            // Distinguish a failed catalog request from a successful empty catalog.
                            if (VGSThemeCatalogService.failureText !== "")
                                return VGSThemeCatalogService.failureText;
                            return I18n.tr("This install ships no theme catalog");
                        }
                        font.pixelSize: Theme.fontSizeMedium
                        color: VGSThemeCatalogService.failureText !== "" ? Theme.error : Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: root
    }
}
