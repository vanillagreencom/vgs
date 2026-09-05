import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property string headerText: ""
    property string detailsText: ""
    property bool showCloseButton: false
    property var closePopout: null
    property var parentPopout: null
    property alias headerActions: headerActionsLoader.sourceComponent

    // THE REFRESH SLOT. Every bar flyout that can re-read something puts the
    // control here, so it is the same glyph in the same place whichever widget
    // the user opened. Before this existed each surface invented its own: one
    // had it at the top, one had it in a footer beside a "Last checked: 4m
    // ago" line, and one that could refresh had no control at all.
    //
    // The freshness label went with them. A timestamp beside a button that
    // fixes it is a reading exercise: the button is always the answer, and
    // every one of these surfaces already re-reads on open.
    //
    // `refreshBusy` spins the icon and blocks a second press, so a surface
    // does not have to build that itself to look like the others.
    property bool refreshable: false
    property bool refreshBusy: false

    signal refreshRequested

    // THE SETTINGS SLOT, for the same reason. Three surfaces had one before
    // this and each built it differently: two drew a bare Rectangle with a
    // MouseArea and no tooltip, one used VgsActionButton, and they disagreed
    // on the glyph — `settings` (a cog, which reads as system settings) on the
    // printer against `tune` (options for the thing in front of you)
    // elsewhere. `tune` wins; the cog belongs to the settings application.
    //
    // The signal says only that the user asked. A surface that pages its
    // settings in place sets `settingsBack` while showing them, which swaps
    // this to a back arrow — the header has no left-hand slot for one, and
    // swapping in place keeps the way out where the pointer already is.
    property bool configurable: false
    property bool settingsBack: false

    signal settingsRequested

    readonly property int headerHeight: popoutHeader.visible ? popoutHeader.height : 0
    readonly property int detailsHeight: popoutDetails.visible ? popoutDetails.implicitHeight : 0

    spacing: 0

    Item {
        id: popoutHeader
        width: parent.width
        // Height tracks the close button so the title's top padding matches the
        // popout's side padding instead of gaining extra space from a taller header.
        height: 32
        visible: headerText.length > 0

        // The title yields to the buttons rather than sliding under them. It
        // had unconstrained width, which was survivable when the cluster was
        // one close button and is not now that a surface can carry refresh,
        // its own actions and settings beside it -- and Mercury's title is an
        // organisation name, as long as the bank says it is.
        StyledText {
            anchors.left: parent.left
            anchors.right: headerActionsRow.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: root.headerText
            font.pixelSize: Theme.fontSizeXLarge
            font.weight: Font.Bold
            color: Theme.surfaceText
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Row {
            id: headerActionsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            // First in the cluster, so it lands in the same spot no matter how
            // many actions a surface adds after it.
            Rectangle {
                id: refreshButton
                width: 32
                height: 32
                radius: Theme.controlRadius
                visible: root.refreshable
                color: refreshArea.containsMouse ? Theme.surfaceContainerHighest
                                                 : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                VgsIcon {
                    id: refreshIcon
                    anchors.centerIn: parent
                    name: "refresh"
                    size: Theme.iconSize - 4
                    color: Theme.surfaceText
                    opacity: root.refreshBusy ? 0.5 : 1

                    RotationAnimator on rotation {
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
                        running: root.refreshBusy
                        onRunningChanged: {
                            if (!running)
                                refreshIcon.rotation = 0;
                        }
                    }
                }

                MouseArea {
                    id: refreshArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !root.refreshBusy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refreshRequested()
                }
            }

            // Surface-specific actions sit between the two framework slots, so
            // refresh and settings keep the outer edges of the cluster however
            // many a surface adds.
            Loader {
                id: headerActionsLoader
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                id: settingsButton
                width: 32
                height: 32
                radius: Theme.controlRadius
                visible: root.configurable
                color: settingsArea.containsMouse ? Theme.surfaceContainerHighest
                                                  : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                VgsIcon {
                    anchors.centerIn: parent
                    name: root.settingsBack ? "arrow_back" : "tune"
                    size: Theme.iconSize - 4
                    color: root.settingsBack ? Theme.primary : Theme.surfaceText
                }

                MouseArea {
                    id: settingsArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.settingsRequested()
                }
            }

            Rectangle {
                id: closeButton
                width: 32
                height: 32
                radius: Theme.controlRadius
                color: closeArea.containsMouse ? Theme.errorHover : Theme.withAlpha(Theme.errorHover, 0)
                visible: root.showCloseButton

                VgsIcon {
                    anchors.centerIn: parent
                    name: "close"
                    size: Theme.iconSize - 4
                    color: closeArea.containsMouse ? Theme.error : Theme.surfaceText
                }

                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: {
                        if (root.closePopout) {
                            root.closePopout();
                        }
                    }
                }
            }
        }
    }

    StyledText {
        id: popoutDetails
        width: parent.width
        text: root.detailsText
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        visible: detailsText.length > 0
        wrapMode: Text.WordWrap
    }

    // A spacer rather than padding on the line above it: a surface with no
    // subtitle hides that line entirely, and the gap under the title has to
    // survive that. This Column's spacing is 0, so this is the whole gap.
    Item {
        width: 1
        height: Theme.popoutHeaderGap
    }
}
