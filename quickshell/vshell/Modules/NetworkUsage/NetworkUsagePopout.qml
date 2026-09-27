import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Modules.NetworkUsage
import qs.Services
import qs.Widgets

VgsPopout {
    id: networkUsagePopout

    layerNamespace: "vshell:network-usage-popout"

    property var parentWidget: null
    property var triggerScreen: null
    property string searchText: ""
    // Tracks whether we currently hold a capture ref, so open/close pairs cleanly.
    property bool _refHeld: false

    function hide() {
        close();
    }

    function show() {
        open();
    }

    function formatRate(bps) {
        if (!bps || bps < 1)
            return "0 B/s";
        if (bps < 1024)
            return bps.toFixed(0) + " B/s";
        if (bps < 1024 * 1024)
            return (bps / 1024).toFixed(1) + " KB/s";
        if (bps < 1024 * 1024 * 1024)
            return (bps / (1024 * 1024)).toFixed(1) + " MB/s";
        return (bps / (1024 * 1024 * 1024)).toFixed(1) + " GB/s";
    }

    // Wide enough for the table, always. The fixed multiple below was the
    // width before, and it cut the last column off; the view reports what its
    // columns actually need and this takes whichever is larger, so the popout
    // cannot be narrower than its own contents at any font size.
    readonly property real chromeWidth: Theme.popoutPadding * 2 + Theme.spacingS * 2
    // Reported UP by the view rather than read down into it: the content lives
    // in a Component, so its ids do not resolve from here.
    property real tableWidth: 0
    popupWidth: Math.round(Math.max(Theme.fontSizeMedium * 34,
                                    networkUsagePopout.tableWidth + networkUsagePopout.chromeWidth))
    popupHeight: Math.round(Theme.fontSizeMedium * 34)
    triggerWidth: 55
    positioning: ""
    screen: triggerScreen
    shouldBeVisible: false

    onBackgroundClicked: close()

    onShouldBeVisibleChanged: {
        if (shouldBeVisible) {
            if (!_refHeld) {
                NetworkUsageService.addRef();
                _refHeld = true;
            }
        } else {
            searchText = "";
            if (_refHeld) {
                NetworkUsageService.removeRef();
                _refHeld = false;
            }
        }
    }

    Component.onDestruction: {
        if (_refHeld) {
            NetworkUsageService.removeRef();
            _refHeld = false;
        }
    }

    content: Component {
        Rectangle {
            id: networkUsageContent

            LayoutMirroring.enabled: I18n.isRtl
            LayoutMirroring.childrenInherit: true

            radius: Theme.cornerRadius
            color: "transparent"
            clip: true
            focus: true

            Component.onCompleted: {
                if (networkUsagePopout.shouldBeVisible)
                    searchField.forceActiveFocus();
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (networkUsagePopout.searchText.length > 0) {
                        networkUsagePopout.searchText = "";
                        event.accepted = true;
                        return;
                    }
                    networkUsagePopout.close();
                    event.accepted = true;
                }
            }

            Connections {
                target: networkUsagePopout
                function onShouldBeVisibleChanged() {
                    if (networkUsagePopout.shouldBeVisible)
                        Qt.callLater(() => searchField.forceActiveFocus());
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.popoutPadding
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    StyledText {
                        text: I18n.tr("Network")
                        font.pixelSize: Theme.fontSizeXLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    VgsTextField {
                        id: searchField
                        Layout.fillWidth: true
                        Layout.minimumWidth: Theme.fontSizeMedium * 7
                        Layout.preferredHeight: Theme.fontSizeMedium * 2.5
                        placeholderText: I18n.tr("Search...")
                        leftIconName: "search"
                        showClearButton: true
                        text: networkUsagePopout.searchText
                        onTextChanged: networkUsagePopout.searchText = text
                        keyForwardTargets: [networkUsageContent]
                    }
                }

                // Live totals. This popout builds its own header, so it applies
                // the shared title gap by hand: the margin makes up what this
                // column's spacing does not already give.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Math.max(0, Theme.popoutHeaderGap - Theme.spacingS)
                    Layout.bottomMargin: Theme.spacingXXS
                    spacing: Theme.spacingL

                    Row {
                        spacing: Theme.spacingXS
                        VgsIcon {
                            name: "arrow_downward"
                            size: Theme.fontSizeMedium
                            color: Theme.info
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: networkUsagePopout.formatRate(NetworkUsageService.totalDown)
                            font.pixelSize: Theme.fontSizeMedium
                            font.family: SettingsData.monoFontFamily
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: Theme.spacingXS
                        VgsIcon {
                            name: "arrow_upward"
                            size: Theme.fontSizeMedium
                            color: Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: networkUsagePopout.formatRate(NetworkUsageService.totalUp)
                            font.pixelSize: Theme.fontSizeMedium
                            font.family: SettingsData.monoFontFamily
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    StyledText {
                        text: NetworkUsageService.apps.length + " " + I18n.tr("apps", "short for applications")
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: SettingsData.monoFontFamily
                        color: Theme.surfaceVariantText
                        Layout.alignment: Qt.AlignVCenter
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.cornerRadius
                    color: Theme.nestedSurface
                    clip: true

                    NetworkUsageView {
                        id: usageView
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        searchText: networkUsagePopout.searchText

                        onNaturalWidthChanged: networkUsagePopout.tableWidth = usageView.naturalWidth
                        Component.onCompleted: networkUsagePopout.tableWidth = usageView.naturalWidth
                    }
                }
            }
        }
    }
}
