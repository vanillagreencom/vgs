import QtQuick
import qs.Common
import qs.Modules.Settings
import qs.Services
import qs.Widgets

FocusScope {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property int currentIndex: 0
    property var parentModal: null
    property Loader _activeLoader: null
    readonly property bool settingsSurface: true
    readonly property bool ready: _activeLoader !== null && _activeLoader.isCurrent && _activeLoader.status === Loader.Ready

    focus: true

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: (parentModal && parentModal.isCompactMode) ? (32 + Theme.spacingS) : Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        anchors.bottomMargin: 0
        anchors.topMargin: 32 + Theme.spacingL
        color: "transparent"

        // Cap and centre the reading column so wide windows do not stretch settings across the full pane.
        Item {
            id: contentColumn
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 820)

            SettingsSectionNav {
                id: sectionNav
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                currentIndex: root.currentIndex
                onSelected: tabIndex => root.parentModal?.setTabIndex(tabIndex)
            }

            Repeater {
                model: SettingsRegistry.tabs

                delegate: Loader {
                    id: tabLoader

                    required property var modelData
                    readonly property bool isCurrent: root.currentIndex === modelData.tabIndex
                    property bool loadedOnce: false

                    anchors.top: sectionNav.bottom
                    anchors.topMargin: sectionNav.visible ? Theme.spacingL : 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    asynchronous: modelData.async === true
                    active: isCurrent || (modelData.keepLoaded === true && loadedOnce)
                    visible: isCurrent && status === Loader.Ready
                    focus: visible
                    source: Qt.resolvedUrl("../../Modules/Settings/" + modelData.source)

                    onIsCurrentChanged: {
                        if (isCurrent)
                            root._activeLoader = tabLoader;
                    }
                    Component.onCompleted: {
                        if (isCurrent)
                            root._activeLoader = tabLoader;
                    }
                    onLoaded: {
                        loadedOnce = true;
                        if (modelData.needsModal && item.hasOwnProperty("parentModal"))
                            item.parentModal = root.parentModal;
                        if (modelData.keybindSearch && item.hasOwnProperty("requestedSearchQuery"))
                            item.requestedSearchQuery = Qt.binding(() => root.parentModal?.keybindSearchQuery ?? "");
                        if (item.hasOwnProperty("pageActive"))
                            item.pageActive = Qt.binding(() => tabLoader.isCurrent);
                        if (visible)
                            Qt.callLater(() => {
                                if (item)
                                    item.forceActiveFocus();
                            });
                    }
                    onVisibleChanged: {
                        if (visible && item)
                            Qt.callLater(() => {
                                if (item)
                                    item.forceActiveFocus();
                            });
                    }
                }
            }

            VgsSpinner {
                anchors.centerIn: parent
                visible: root._activeLoader !== null && root._activeLoader.status === Loader.Loading
            }
        }
    }
}
