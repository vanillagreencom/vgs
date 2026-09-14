import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // The plugin's daemon owns the count poll, the update launch and the
    // counted state. This widget, one per screen, renders them.
    PluginDaemonLink {
        id: daemonLink
        pluginService: root.pluginService
        pluginId: root.pluginId
        watching: root.effectiveVisible
    }
    readonly property var daemon: daemonLink.daemon

    // Until the daemon Instantiator registers the instance there is no count
    // yet, which is the same state as a check still running.
    readonly property bool loading: root.daemon ? root.daemon.loading : true
    readonly property int repoCount: root.daemon ? root.daemon.repoCount : 0
    readonly property int aurCount: root.daemon ? root.daemon.aurCount : 0
    readonly property int toolsCount: root.daemon ? root.daemon.toolsCount : 0
    readonly property bool toolsAvailable: root.daemon ? root.daemon.toolsAvailable : false
    readonly property string toolsError: root.daemon ? root.daemon.toolsError : ""
    readonly property var packages: root.daemon ? root.daemon.packages : []
    readonly property string errorText: root.daemon ? root.daemon.errorText : ""
    readonly property int orphanCount: root.daemon ? root.daemon.orphanCount : 0
    readonly property var orphans: root.daemon ? root.daemon.orphans : []
    readonly property int totalCount: root.daemon ? root.daemon.totalCount : 0
    readonly property bool useBackend: root.daemon ? root.daemon.useBackend : false
    readonly property bool allClear: root.daemon ? root.daemon.allClear : false
    readonly property bool refreshBusy: root.daemon ? root.daemon.refreshBusy : true

    // Hide the source row until a data source is known. It is the only thing
    // left in that footer: the refresh control moved to the shared header slot
    // and the "last checked" stamp beside it went with it.
    readonly property string sourceLabel: root.daemon ? root.daemon.sourceLabel : ""

    // Which sheet the popout shows. Per screen, because it follows what the
    // person looking at that bar clicked.
    property bool showOrphans: false
    onOrphanCountChanged: {
        if (root.orphanCount === 0)
            root.showOrphans = false;
    }

    // Use state color for pill text while retaining the bar icon color.
    readonly property color accentColor: root.errorText.length > 0 ? Theme.error : (root.totalCount > 0 ? Theme.primary : Theme.surfaceVariantText)

    function pillText() {
        if (root.loading)
            return "…";
        if (root.errorText.length > 0)
            return "!";
        return String(root.totalCount);
    }

    function manualRefresh() {
        if (root.daemon)
            root.daemon.manualRefresh();
    }

    // Closing the popout belongs to the screen that opened it; the upgrade
    // itself is one machine-wide action the daemon owns.
    function launch(mode, sourcePopout) {
        if (sourcePopout && sourcePopout.closePopout)
            sourcePopout.closePopout();
        if (root.daemon)
            root.daemon.launch(mode);
    }

    function reviewOrphans() {
        if (root.daemon)
            root.daemon.reviewOrphans();
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: "upgrade"
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.accentColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: "upgrade"
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                color: root.accentColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "System Updates"
            detailsText: root.loading ? "Checking…" : (root.errorText.length > 0 ? root.errorText : (root.totalCount > 0 ? (root.totalCount + " available  (" + root.repoCount + " repo - " + root.aurCount + " aur" + (root.toolsAvailable ? " - " + (root.toolsError ? "tools ?" : root.toolsCount + " tools") : "") + ")") : (root.toolsError ? "Up to date (tools check failed)" : "")))
            showCloseButton: true

            // Bar -> Widgets, where a bundled plugin's settings live.
            configurable: true
            onSettingsRequested: PopoutService.openSettingsWithTab("bar_widgets")

            // The shared header slot. This control used to sit in the footer
            // beside a "Last checked" line; it is in the header now, where
            // every other bar flyout keeps it.
            refreshable: true
            refreshBusy: root.refreshBusy
            onRefreshRequested: root.manualRefresh()

            Column {
                id: contentCol
                width: parent.width
                spacing: Theme.spacingM

                readonly property int innerWidth: width - leftPadding - rightPadding

                Item {
                    width: contentCol.innerWidth
                    height: toggleLink.implicitHeight
                    visible: !root.loading && root.orphanCount > 0

                    StyledText {
                        id: toggleLink
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.showOrphans ? (root.totalCount + " packages") : (root.orphanCount + " orphaned")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        font.underline: linkArea.containsMouse
                        color: Theme.primary

                        MouseArea {
                            id: linkArea
                            anchors.fill: parent
                            anchors.margins: -Theme.spacingXS
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showOrphans = !root.showOrphans
                        }
                    }
                }

                Item {
                    id: bodySwap
                    width: contentCol.innerWidth
                    // Fixed to the taller sheet so toggling never resizes the popout
                    // window — a per-frame Wayland surface resize is what flickers.
                    // Only the internal opacity cross-fade animates.
                    height: Math.max(updatesBody.implicitHeight, orphansBody.implicitHeight)
                    clip: true

                    Column {
                        id: updatesBody
                        width: parent.width
                        spacing: Theme.spacingM

                        opacity: root.showOrphans ? 0 : 1
                        visible: opacity > 0
                        Behavior on opacity {
                            NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing }
                        }

                        StyledText {
                            visible: root.errorText.length === 0 && root.toolsError.length > 0
                            width: parent.width
                            text: "Dev tools check failed: " + root.toolsError
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.error
                        }

                        StyledText {
                            visible: root.errorText.length > 0
                            width: parent.width
                            text: root.errorText
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledRect {
                            width: parent.width
                            height: Math.min(root.packages.length * 44 + Theme.spacingS * 2, 264)
                            visible: root.errorText.length === 0 && root.packages.length > 0
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            clip: true

                            ListView {
                                id: pkgList
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                anchors.rightMargin: 2
                                model: root.packages
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ScrollBar.vertical: VgsScrollbar {
                                }

                                delegate: Item {
                                    width: pkgList.width - Theme.spacingS + 2
                                    height: 44

                                    Rectangle {
                                        id: srcPill
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        radius: height / 2
                                        height: srcPillText.implicitHeight + 3
                                        width: srcPillText.implicitWidth + Theme.spacingS * 2
                                        color: Theme.withAlpha(srcPillText.color, 0.18)

                                        StyledText {
                                            id: srcPillText
                                            anchors.centerIn: parent
                                            text: modelData.src === "aur" ? "aur" : (modelData.src === "tools" ? "tools" : "system")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.weight: Font.Medium
                                            color: modelData.src === "aur" ? Theme.secondary : (modelData.src === "tools" ? Theme.tertiary : Theme.primary)
                                        }
                                    }

                                    Column {
                                        anchors.left: parent.left
                                        anchors.right: srcPill.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        StyledText {
                                            width: parent.width
                                            text: modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Bold
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: (modelData.old ? modelData.old + "  →  " : "") + modelData.new
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        UpToDateState {
                            width: parent.width
                            visible: root.allClear
                            toolsAvailable: root.toolsAvailable
                        }

                        UpdateActions {
                            width: parent.width
                            visible: !root.allClear
                            host: root
                            onLaunchRequested: mode => root.launch(mode, popout)
                        }
                    }

                    Column {
                        id: orphansBody
                        width: parent.width
                        spacing: Theme.spacingS
                        opacity: root.showOrphans ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity {
                            NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing }
                        }

                        StyledText {
                            width: parent.width
                            text: "Orphaned packages"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: "Installed as dependencies, no longer required by anything."
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        StyledRect {
                            visible: root.orphans.length > 0
                            width: parent.width
                            height: Math.min(root.orphans.length * 30 + Theme.spacingS * 2, 240)
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            clip: true

                            ListView {
                                id: orphanList
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                anchors.rightMargin: 2
                                model: root.orphans
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ScrollBar.vertical: VgsScrollbar {
                                }

                                delegate: Item {
                                    width: orphanList.width - Theme.spacingS + 2
                                    height: 30

                                    StyledText {
                                        id: oName
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        width: Math.min(implicitWidth, parent.width * 0.6)
                                    }

                                    StyledText {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.ver
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideLeft
                                        width: parent.width - oName.width - Theme.spacingS
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }

                        StyledText {
                            visible: root.orphans.length === 0
                            width: parent.width
                            text: "No orphaned packages."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        VgsButton {
                            width: parent.width
                            visible: String(pluginData.orphanReviewCommand || "").trim().length > 0
                            text: "Review orphans"
                            iconName: "manage_search"
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            onClicked: root.reviewOrphans()
                        }
                    }
                }

                Column {
                    id: footer
                    width: contentCol.innerWidth
                    spacing: Theme.spacingXS
                    visible: !root.showOrphans

                    // The CLI count can differ from what paru reinstalls. Show that caveat
                    // only on the CLI path.
                    StyledText {
                        width: parent.width
                        visible: !root.useBackend && root.errorText.length === 0 && !root.allClear
                        text: "For repo packages use Update System / Update All (or paru -Syu); paru -S <pkg> may still show the old local sync DB."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    // Which tool answered, and nothing else.
                    StyledText {
                        width: parent.width
                        visible: root.sourceLabel.length > 0
                        text: "Source: " + root.sourceLabel
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
