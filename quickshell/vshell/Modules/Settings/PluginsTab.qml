import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

FocusScope {
    id: pluginsTab

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string expandedPluginId: ""
    property bool isRefreshingPlugins: false
    property var parentModal: null
    property var installedPluginsData: ({})
    property bool isReloading: false
    property alias sharedTooltip: sharedTooltip
    property bool isSearchExpanded: false
    property string searchQuery: ""
    property var filteredPlugins: []

    readonly property var pluginsWithUpdates: {
        if (!VGSBackendService.installedPlugins) return [];
        return VGSBackendService.installedPlugins.filter(p => {
            if (p.hasUpdate !== true)
                return false;
            const local = PluginService.availablePlugins[p.id] || PluginService.availablePlugins[p.name];
            return !local || local.source !== "bundled";
        });
    }

    function updateFilteredPlugins() {
        var query = searchQuery.toLowerCase();
        filteredPlugins = PluginService.availablePluginsList.filter(plugin => {
            // VGS-owned bundled modules are configured as normal widgets and
            // features in their owning settings pages, not as extensions.
            if (plugin.source === "bundled")
                return false;
            if (!query)
                return true;
            var name = (plugin.name || "").toLowerCase();
            var desc = (plugin.description || "").toLowerCase();
            var author = (plugin.author || "").toLowerCase();
            return name.includes(query) || desc.includes(query) || author.includes(query);
        });
    }

    Connections {
        target: PluginService
        function onAvailablePluginsListChanged() {
            pluginsTab.updateFilteredPlugins();
        }
    }

    focus: true

    VgsInlineTooltip {
        id: sharedTooltip
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS

            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                iconName: "extension"
                title: I18n.tr("Plugin Management")

                StyledText {
                    text: I18n.tr("Manage third-party and system extensions installed outside VGS")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignLeft
                }

                StyledRect {
                    width: parent.width
                    height: vgsWarningColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.warning, 0.1)
                    border.color: Theme.warning
                    border.width: 1
                    visible: !VGSBackendService.pluginsAvailable

                    Column {
                        id: vgsWarningColumn
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        Row {
                            spacing: Theme.spacingXS

                            VgsIcon {
                                name: "warning"
                                size: 16
                                color: Theme.warning
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: I18n.tr("Online Plugin Catalog Unavailable")
                                font.pixelSize: Theme.settingsFontSize
                                color: Theme.warning
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        StyledText {
                            text: I18n.tr("Browsing and update checks require the VGS backend. Installed plugins still work.")
                            font.pixelSize: Theme.settingsFontSize - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                        }
                    }
                }

                StyledRect {
                    id: incompatWarning
                    property var incompatPlugins: []
                    width: parent.width
                    height: incompatWarningColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.error, 0.1)
                    border.color: Theme.error
                    border.width: 1
                    visible: incompatPlugins.length > 0

                    function refresh() {
                        incompatPlugins = PluginService.getIncompatiblePlugins().filter(plugin => plugin.source !== "bundled");
                    }

                    Component.onCompleted: Qt.callLater(refresh)

                    Column {
                        id: incompatWarningColumn
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        Row {
                            spacing: Theme.spacingXS

                            VgsIcon {
                                name: "error"
                                size: 16
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: I18n.tr("Incompatible Plugins Loaded")
                                font.pixelSize: Theme.settingsFontSize
                                color: Theme.error
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        StyledText {
                            text: I18n.tr("Some plugins require a newer version of VGS:") + " " + incompatWarning.incompatPlugins.map(p => p.name + " (" + p.requires_vgs + ")").join(", ")
                            font.pixelSize: Theme.settingsFontSize - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    Connections {
                        target: PluginService
                        function onPluginLoaded() {
                            incompatWarning.refresh();
                        }
                        function onPluginUnloaded() {
                            incompatWarning.refresh();
                        }
                    }

                    Connections {
                        target: ShellVersionService
                        function onSemverVersionChanged() {
                            incompatWarning.refresh();
                        }
                    }
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingM

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Browse")
                        iconName: "store"
                        enabled: VGSBackendService.pluginsAvailable
                        onClicked: {
                            showPluginBrowser();
                        }
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Scan")
                        iconName: "refresh"
                        onClicked: {
                            pluginsTab.isRefreshingPlugins = true;
                            PluginService.scanPlugins();
                            if (VGSBackendService.pluginsAvailable) {
                                VGSBackendService.listInstalled();
                            }
                            pluginsTab.refreshPluginList();
                        }
                    }

                    VgsButton {
                        variant: "secondary"
                        text: PluginService.pluginDirectoryExists ? I18n.tr("Open Folder") : I18n.tr("Create Folder")
                        iconName: PluginService.pluginDirectoryExists ? "folder_open" : "create_new_folder"
                        onClicked: {
                            if (PluginService.pluginDirectoryExists) {
                                PluginService.openPluginDirectory();
                            } else {
                                PluginService.createPluginDirectory();
                                ToastService.showInfo(I18n.tr("Created plugin directory: %1").arg(PluginService.pluginDirectory));
                            }
                        }
                    }

                    VgsButton {
                        text: I18n.tr("Update All")
                        iconName: "download"
                        enabled: VGSBackendService.pluginsAvailable && pluginsTab.pluginsWithUpdates.length > 0
                        onClicked: {
                            showPluginUpdatesDialog();
                        }
                    }
                }
            }

            PluginUpdatesDialog {
                id: pluginUpdatesDialogItem
                width: parent.width
            }

            SettingsCard {
                width: parent.width
                iconName: "folder"
                title: I18n.tr("Plugin Directory")

                StyledText {
                    text: PluginService.pluginDirectory
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    font.family: "monospace"
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }

                StyledText {
                    text: I18n.tr("Place plugin directories here. Each plugin should have a plugin.json manifest file.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }
            }

            SettingsCard {
                width: parent.width
                title: I18n.tr("Installed Extensions")

                headerActions: [
                    VgsActionButton {
                        id: searchIconBtn
                        iconName: "search"
                        iconSize: 20
                        iconColor: pluginsTab.isSearchExpanded ? Theme.primary : Theme.surfaceVariantText
                        onClicked: {
                            pluginsTab.isSearchExpanded = !pluginsTab.isSearchExpanded;
                            if (pluginsTab.isSearchExpanded) {
                                Qt.callLater(() => pluginSearchField.forceActiveFocus());
                            } else {
                                pluginSearchField.text = "";
                                pluginsTab.searchQuery = "";
                                pluginsTab.updateFilteredPlugins();
                            }
                        }
                    }
                ]

                VgsTextField {
                    id: pluginSearchField
                    width: parent.width
                    visible: pluginsTab.isSearchExpanded || height > 0
                    height: pluginsTab.isSearchExpanded ? 48 : 0
                    opacity: pluginsTab.isSearchExpanded ? 1 : 0
                    clip: true
                    placeholderText: I18n.tr("Search installed extensions…")
                    leftIconName: "search"
                    showClearButton: true

                    Behavior on height {
                        enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }

                    Behavior on opacity {
                        enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                        NumberAnimation {
                            duration: Theme.shortDuration
                        }
                    }

                    onTextEdited: {
                        pluginsTab.searchQuery = text;
                        pluginsTab.updateFilteredPlugins();
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    Repeater {
                        id: pluginRepeater
                        model: pluginsTab.filteredPlugins

                        PluginListItem {
                            pluginData: modelData
                            expandedPluginId: pluginsTab.expandedPluginId
                            hasUpdate: {
                                if (!VGSBackendService.pluginsAvailable)
                                    return false;
                                return pluginsTab.installedPluginsData[pluginId] || pluginsTab.installedPluginsData[pluginName] || false;
                            }
                            isReloading: pluginsTab.isReloading
                            sharedTooltip: pluginsTab.sharedTooltip
                            onExpandedPluginIdChanged: {
                                pluginsTab.expandedPluginId = expandedPluginId;
                            }
                            onIsReloadingChanged: {
                                pluginsTab.isReloading = isReloading;
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("No extensions found") + "\n" + I18n.tr("Place third-party plugins in %1").arg(PluginService.pluginDirectory)
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        visible: pluginRepeater.model && pluginRepeater.model.length === 0
                    }
                }
            }
        }
    }

    function refreshPluginList() {
        pluginsTab.isRefreshingPlugins = false;
    }

    Connections {
        target: PluginService
        function onPluginLoaded() {
            refreshPluginList();
            if (isReloading) {
                isReloading = false;
            }
        }
        function onPluginUnloaded() {
            refreshPluginList();
            if (!isReloading && pluginsTab.expandedPluginId !== "" && !PluginService.isPluginLoaded(pluginsTab.expandedPluginId)) {
                pluginsTab.expandedPluginId = "";
            }
        }
        function onPluginListUpdated() {
            if (VGSBackendService.pluginsAvailable) {
                VGSBackendService.listInstalled();
            }
            refreshPluginList();
        }
        function onPluginDataChanged(pluginId) {
            var plugin = PluginService.availablePlugins[pluginId];
            if (!plugin || !PluginService.isPluginLoaded(pluginId))
                return;
            var isLauncher = plugin.type === "launcher" || (plugin.capabilities && plugin.capabilities.includes("launcher"));
            if (isLauncher) {
                pluginsTab.isReloading = true;
                PluginService.reloadPlugin(pluginId);
            }
        }
    }

    Connections {
        target: VGSBackendService
        function onPluginsListReceived(plugins) {
            if (!pluginBrowserLoader.item)
                return;
            pluginBrowserLoader.item.isLoading = false;
            pluginBrowserLoader.item.allPlugins = plugins;
            pluginBrowserLoader.item.updateFilteredPlugins();
        }
        function onInstalledPluginsReceived(plugins) {
            var pluginMap = {};
            for (var i = 0; i < plugins.length; i++) {
                var plugin = plugins[i];
                var hasUpdate = plugin.hasUpdate || false;
                if (plugin.id) {
                    pluginMap[plugin.id] = hasUpdate;
                }
                if (plugin.name) {
                    pluginMap[plugin.name] = hasUpdate;
                }
            }
            installedPluginsData = pluginMap;
            Qt.callLater(refreshPluginList);
        }
        function onOperationSuccess(message) {
            ToastService.showInfo(message);
        }
        function onOperationError(error) {
            ToastService.showError(error);
        }
    }

    Component.onCompleted: {
        updateFilteredPlugins();
        if (VGSBackendService.pluginsAvailable)
            VGSBackendService.listInstalled();
        if (PopoutService.pendingPluginInstall)
            Qt.callLater(showPluginBrowser);
    }

    Connections {
        target: PopoutService
        function onPendingPluginInstallChanged() {
            if (PopoutService.pendingPluginInstall)
                showPluginBrowser();
        }
    }

    LazyLoader {
        id: pluginBrowserLoader
        active: false

        PluginBrowser {
            id: pluginBrowserItem

            Component.onCompleted: {
                pluginBrowserItem.parentModal = pluginsTab.parentModal;
            }
        }
    }

    function showPluginBrowser() {
        pluginBrowserLoader.active = true;
        if (pluginBrowserLoader.item)
            pluginBrowserLoader.item.show();
    }

    function showPluginUpdatesDialog() {
        pluginUpdatesDialogItem.show(pluginsTab.pluginsWithUpdates);
    }
}
