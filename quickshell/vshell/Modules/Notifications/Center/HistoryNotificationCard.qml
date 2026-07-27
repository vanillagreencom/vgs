import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    required property var historyItem
    property bool isSelected: false
    property bool keyboardNavigationActive: false
    property bool descriptionExpanded: NotificationService.expandedMessages[historyItem?.id ? (historyItem.id + "_hist") : ""] || false
    property bool __initialized: false

    Component.onCompleted: {
        Qt.callLater(() => {
            if (root)
                root.__initialized = true;
        });
    }

    readonly property bool compactMode: SettingsData.notificationCompactMode
    readonly property real cardPadding: compactMode ? Theme.notificationCardPaddingCompact : Theme.notificationCardPadding
    readonly property real iconSize: compactMode ? Theme.notificationIconSizeCompact : Theme.notificationIconSizeNormal
    readonly property real collapsedContentHeight: Math.max(iconSize, historyTextColumn.implicitHeight)
    readonly property real baseCardHeight: cardPadding * 2 + collapsedContentHeight

    // Text must clear the top-right controls. Derive the inset from the buttons
    // actually shown, rather than a fixed reserve that was narrower than them.
    readonly property real actionButtonSize: compactMode ? 24 : 28
    readonly property real actionButtonTopMargin: cardPadding + (historyHeaderRow.implicitHeight - actionButtonSize) / 2
    readonly property bool hasOpenAction: (historyItem?.url || "") !== ""
    readonly property real contentRightInset: Theme.spacingL + actionButtonSize + (hasOpenAction ? actionButtonSize + Theme.spacingXS : 0) + Theme.spacingS

    width: parent ? parent.width : 400
    height: baseCardHeight
    radius: Theme.cornerRadius
    clip: false
    readonly property bool shadowsAllowed: Theme.elevationEnabled && Quickshell.env("VGS_DISABLE_LAYER") !== "true" && Quickshell.env("VGS_DISABLE_LAYER") !== "1"

    ElevationShadow {
        id: shadowLayer
        anchors.fill: parent
        z: -1
        level: Theme.elevationLevel1
        fallbackOffset: 1
        targetRadius: root.radius
        targetColor: root.color
        borderColor: root.border.color
        borderWidth: root.border.width
        shadowOpacity: Theme.popupShadowOpacityScale
        shadowEnabled: root.shadowsAllowed
    }

    color: {
        if (isSelected && keyboardNavigationActive)
            return Theme.primaryPressed;
        return Theme.floatingSurfaceHigh;
    }
    border.color: {
        if (isSelected && keyboardNavigationActive)
            return Theme.withAlpha(Theme.primary, 0.5);
        if (historyItem.urgency === 2)
            return Theme.primarySelected;
        return Theme.outlineMedium;
    }
    border.width: {
        if (isSelected && keyboardNavigationActive)
            return 1.5;
        if (historyItem.urgency === 2)
            return 2;
        return Theme.layerOutlineWidth;
    }

    Behavior on border.color {
        enabled: root.__initialized
        ColorAnimation {
            duration: root.__initialized ? Theme.shortDuration : 0
            easing.type: Theme.standardEasing
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        visible: historyItem.urgency === 2
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0.0
                color: Theme.primary
            }
            GradientStop {
                position: 0.02
                color: Theme.primary
            }
            GradientStop {
                position: 0.021
                color: "transparent"
            }
        }
    }

    Item {
        id: contentItem

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: cardPadding
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: root.contentRightInset
        height: collapsedContentHeight

        VgsCircularImage {
            id: iconContainer
            cacheImages: false
            readonly property string rawImage: historyItem.image || ""
            readonly property string iconFromImage: {
                if (rawImage.startsWith("image://icon/"))
                    return rawImage.substring(13);
                return "";
            }
            readonly property bool imageHasSpecialPrefix: {
                const icon = iconFromImage;
                return icon.startsWith("material:") || icon.startsWith("svg:") || icon.startsWith("unicode:") || icon.startsWith("image:");
            }
            readonly property bool hasNotificationImage: rawImage !== "" && (!rawImage.startsWith("image://icon/") || iconFromImage.startsWith("/"))
            readonly property string resolvedImage: iconFromImage.startsWith("/") ? ("file://" + iconFromImage) : rawImage

            width: iconSize
            height: iconSize
            anchors.left: parent.left
            anchors.top: parent.top

            imageSource: {
                if (hasNotificationImage)
                    return resolvedImage;
                if (imageHasSpecialPrefix)
                    return "";
                const appIcon = historyItem.appIcon;
                if (!appIcon)
                    return "";
                if (appIcon.startsWith("file://") || appIcon.startsWith("http://") || appIcon.startsWith("https://") || appIcon.includes("/"))
                    return appIcon;
                return "";
            }

            hasImage: hasNotificationImage
            fallbackIcon: {
                if (imageHasSpecialPrefix)
                    return iconFromImage;
                return historyItem.appIcon || iconFromImage || "";
            }
            fallbackText: {
                const appName = historyItem.appName || "?";
                return appName.charAt(0).toUpperCase();
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: width / 2
                color: "transparent"
                border.color: root.color
                border.width: 5
                visible: parent.hasImage
                antialiasing: true
            }
        }

        Item {
            anchors.left: iconContainer.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.top: parent.top
            height: historyTextColumn.implicitHeight

            Column {
                id: historyTextColumn
                width: parent.width
                spacing: Theme.notificationContentSpacing

                Row {
                    id: historyHeaderRow
                    width: parent.width
                    spacing: Theme.spacingXS

                    Item {
                        width: Math.max(0, parent.width - historySeparator.implicitWidth - historyTimeText.implicitWidth - parent.spacing * 2)
                        height: historyTitleText.implicitHeight
                        visible: historyTitleText.text.length > 0

                        StyledText {
                            id: historyTitleText
                            anchors.fill: parent
                            text: {
                                let title = historyItem.summary || "";
                                const appName = historyItem.appName || "";
                                const prefix = appName + " • ";
                                if (appName && title.toLowerCase().startsWith(prefix.toLowerCase())) {
                                    title = title.substring(prefix.length);
                                }
                                return title;
                            }
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }
                    StyledText {
                        id: historySeparator
                        text: (historyTitleText.text.length > 0 && historyTimeText.text.length > 0) ? "•" : ""
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Normal
                    }
                    StyledText {
                        id: historyTimeText
                        text: NotificationService.formatHistoryTime(historyItem.timestamp)
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Normal
                        visible: text.length > 0
                    }
                }

                StyledText {
                    id: descriptionText
                    property bool hasMoreText: truncated

                    text: historyItem.htmlBody || historyItem.body || ""
                    textFormat: Text.StyledText
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    width: parent.width
                    elide: descriptionExpanded ? Text.ElideNone : Text.ElideRight
                    maximumLineCount: descriptionExpanded ? -1 : (compactMode ? 1 : 2)
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                    linkColor: Theme.primary
                    onLinkActivated: link => Qt.openUrlExternally(link)

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : (parent.hasMoreText || descriptionExpanded) ? Qt.PointingHandCursor : Qt.ArrowCursor

                        onClicked: mouse => {
                            if (!parent.hoveredLink && (parent.hasMoreText || descriptionExpanded)) {
                                const messageId = historyItem?.id ? (historyItem.id + "_hist") : "";
                                NotificationService.toggleMessageExpansion(messageId);
                            }
                        }

                        propagateComposedEvents: true
                        onPressed: mouse => {
                            if (parent.hoveredLink)
                                mouse.accepted = false;
                        }
                        onReleased: mouse => {
                            if (parent.hoveredLink)
                                mouse.accepted = false;
                        }
                    }
                }
            }
        }
    }

    // Persisted "Open" affordance: the live freedesktop action is long gone for
    // a history entry, so open the URL captured from the body at save time.
    VgsActionButton {
        id: historyOpenButton
        visible: (historyItem?.url || "") !== ""
        anchors.top: parent.top
        anchors.right: historyCloseButton.left
        anchors.topMargin: root.actionButtonTopMargin
        anchors.rightMargin: Theme.spacingXS
        iconName: "open_in_new"
        iconSize: compactMode ? 15 : 17
        buttonSize: root.actionButtonSize
        onClicked: Quickshell.execDetached(["xdg-open", historyItem.url])
    }

    VgsActionButton {
        id: historyCloseButton
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.actionButtonTopMargin
        anchors.rightMargin: Theme.spacingL
        iconName: "close"
        iconSize: compactMode ? 16 : 18
        buttonSize: root.actionButtonSize
        onClicked: NotificationService.removeFromHistory(historyItem.id)
    }
}
