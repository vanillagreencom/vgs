import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    property string searchText: ""

    function formatRate(bps) {
        if (!bps || bps < 1)
            return "0";
        if (bps < 1024)
            return bps.toFixed(0) + " B/s";
        if (bps < 1024 * 1024)
            return (bps / 1024).toFixed(1) + " K/s";
        if (bps < 1024 * 1024 * 1024)
            return (bps / (1024 * 1024)).toFixed(1) + " M/s";
        return (bps / (1024 * 1024 * 1024)).toFixed(1) + " G/s";
    }

    readonly property var filteredApps: {
        let apps = (NetworkUsageService.apps || []).slice();

        if (searchText.length > 0) {
            const search = searchText.toLowerCase();
            apps = apps.filter(a => (a.name || "").toLowerCase().includes(search));
        }

        const key = NetworkUsageService.sortBy;
        const asc = NetworkUsageService.sortAscending;
        apps.sort((a, b) => {
            let result;
            if (key === "name") {
                result = (a.name || "").toLowerCase().localeCompare((b.name || "").toLowerCase());
            } else {
                result = (b[key] || 0) - (a[key] || 0);
            }
            return asc ? -result : result;
        });

        return apps;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 36

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                spacing: 0

                SortableHeader {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 160
                    text: I18n.tr("Application")
                    sortKey: "name"
                    alignment: Text.AlignLeft
                    onClicked: NetworkUsageService.toggleSort("name")
                }

                SortableHeader {
                    Layout.preferredWidth: 110
                    text: I18n.tr("Download")
                    sortKey: "down"
                    alignment: Text.AlignLeft
                    onClicked: NetworkUsageService.toggleSort("down")
                }

                SortableHeader {
                    Layout.preferredWidth: 110
                    text: I18n.tr("Upload")
                    sortKey: "up"
                    alignment: Text.AlignLeft
                    onClicked: NetworkUsageService.toggleSort("up")
                }

                SortableHeader {
                    Layout.preferredWidth: 70
                    text: I18n.tr("Conns", "short for connections")
                    sortKey: "connections"
                    alignment: Text.AlignLeft
                    onClicked: NetworkUsageService.toggleSort("connections")
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.outlineLight
        }

        VgsListView {
            id: appListView

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXXS

            states: [
                State {
                    name: "snap"
                    when: Theme.snapListModelChanges
                    PropertyChanges {
                        target: appListView
                        add: null
                        remove: null
                        displaced: null
                        move: null
                    }
                }
            ]

            model: ScriptModel {
                values: root.filteredApps
                objectProp: "name"
            }

            delegate: AppItem {
                required property var modelData

                width: appListView.width
                app: modelData
            }

            // Empty / setup states
            Item {
                anchors.centerIn: parent
                width: Math.min(parent.width - Theme.spacingL * 2, 360)
                height: emptyColumn.implicitHeight
                visible: root.filteredApps.length === 0

                Column {
                    id: emptyColumn
                    width: parent.width
                    spacing: Theme.spacingM

                    readonly property bool isLoading: NetworkUsageService.available && !NetworkUsageService.needsSetup && NetworkUsageService.warmingUp

                    VgsSpinner {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: 36
                        color: Theme.primary
                        visible: emptyColumn.isLoading
                        running: visible
                    }

                    VgsIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !emptyColumn.isLoading
                        name: {
                            if (NetworkUsageService.needsSetup)
                                return "lock";
                            if (!NetworkUsageService.available)
                                return "help";
                            if (root.searchText.length > 0)
                                return "search_off";
                            return "wifi_tethering";
                        }
                        size: 36
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        text: {
                            if (!NetworkUsageService.available)
                                return I18n.tr("bandwhich is not installed");
                            if (NetworkUsageService.needsSetup)
                                return I18n.tr("Per-app traffic needs a one-time setup");
                            if (emptyColumn.isLoading)
                                return I18n.tr("Measuring network traffic…");
                            if (root.searchText.length > 0)
                                return I18n.tr("No matching applications");
                            return I18n.tr("No network activity");
                        }
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: SettingsData.monoFontFamily
                        color: Theme.surfaceVariantText
                        visible: NetworkUsageService.needsSetup || !NetworkUsageService.available
                        text: NetworkUsageService.available ? "vshell net-usage setup" : "install bandwhich, then: vshell net-usage setup"
                    }
                }
            }
        }
    }

    component SortableHeader: Item {
        id: headerItem

        property string text: ""
        property string sortKey: ""
        property int alignment: Text.AlignHCenter

        signal clicked

        readonly property bool isActive: sortKey === NetworkUsageService.sortBy

        height: 36

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cornerRadius
            color: headerItem.isActive ? Theme.primaryHover : (headerMouseArea.containsMouse ? Theme.surfaceTextLight : Theme.withAlpha(Theme.surfaceTextLight, 0))

            Behavior on color {
                ColorAnimation {
                    duration: Theme.shortDuration
                }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            spacing: Theme.spacingXS

            Item {
                Layout.fillWidth: headerItem.alignment === Text.AlignLeft
                visible: headerItem.alignment !== Text.AlignLeft
            }

            StyledText {
                text: headerItem.text
                font.pixelSize: Theme.fontSizeSmall
                font.family: SettingsData.monoFontFamily
                font.weight: headerItem.isActive ? Font.Bold : Font.Medium
                color: headerItem.isActive ? Theme.primary : Theme.surfaceText
                opacity: headerItem.isActive ? 1 : 0.8
            }

            VgsIcon {
                name: NetworkUsageService.sortAscending ? "arrow_upward" : "arrow_downward"
                size: Theme.fontSizeSmall
                color: Theme.primary
                visible: headerItem.isActive
            }

            Item {
                Layout.fillWidth: headerItem.alignment !== Text.AlignLeft
                visible: headerItem.alignment === Text.AlignLeft
            }
        }

        MouseArea {
            id: headerMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: headerItem.clicked()
        }
    }

    component AppItem: Rectangle {
        id: appItemRoot

        property var app: null

        readonly property string appName: app?.name ?? ""
        readonly property real appUp: app?.up ?? 0
        readonly property real appDown: app?.down ?? 0
        readonly property int appConns: app?.connections ?? 0

        height: 40
        radius: Theme.cornerRadius
        color: appMouseArea.containsMouse ? Theme.primaryBackground : Theme.withAlpha(Theme.primaryBackground, 0)
        border.color: appMouseArea.containsMouse ? Theme.primaryHover : Theme.withAlpha(Theme.primaryHover, 0)
        border.width: 1
        clip: true

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
            }
        }

        MouseArea {
            id: appMouseArea
            anchors.fill: parent
            hoverEnabled: true
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            spacing: 0

            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: 160
                height: parent.height

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    VgsIcon {
                        name: DgopService.getProcessIcon(appItemRoot.appName)
                        size: Theme.iconSize - 4
                        color: Theme.surfaceText
                        opacity: 0.8
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: appItemRoot.appName
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: SettingsData.monoFontFamily
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, 220)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item {
                Layout.preferredWidth: 110
                height: parent.height

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    VgsIcon {
                        name: "arrow_downward"
                        size: Theme.fontSizeSmall
                        color: Theme.info
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: root.formatRate(appItemRoot.appDown)
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: SettingsData.monoFontFamily
                        font.weight: Font.Bold
                        color: appItemRoot.appDown > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item {
                Layout.preferredWidth: 110
                height: parent.height

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    VgsIcon {
                        name: "arrow_upward"
                        size: Theme.fontSizeSmall
                        color: Theme.error
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: root.formatRate(appItemRoot.appUp)
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: SettingsData.monoFontFamily
                        font.weight: Font.Bold
                        color: appItemRoot.appUp > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Item {
                Layout.preferredWidth: 70
                height: parent.height

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: appItemRoot.appConns.toString()
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: SettingsData.monoFontFamily
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
