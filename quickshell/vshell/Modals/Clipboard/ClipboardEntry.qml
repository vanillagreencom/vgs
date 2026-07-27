import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    required property var entry
    required property int itemIndex
    required property bool isSelected
    required property var modal
    required property var listView

    signal copyRequested
    signal pasteRequested
    signal deleteRequested
    signal pinRequested(var targetEntry)
    signal unpinRequested(var targetEntry)
    signal editRequested
    signal contextMenuRequested(real mouseX, real mouseY)

    readonly property string entryType: modal ? modal.getEntryType(entry) : "text"
    readonly property string entryPreview: modal ? modal.getEntryPreview(entry) : ""
    readonly property int previewMaxLines: entryType === "long_text" ? 3 : 1
    readonly property var pinnedDuplicateEntry: !entry.pinned ? ClipboardService.getPinnedEntryByHash(entry.hash) : null
    readonly property bool hasPinnedDuplicate: pinnedDuplicateEntry !== null
    readonly property bool effectivePinned: entry.pinned || hasPinnedDuplicate
    readonly property var visibleEntryActions: SettingsData.clipboardVisibleEntryActions || ["pin", "edit", "delete"]
    readonly property bool showCopyAction: visibleEntryActions.includes("copy")
    readonly property bool showPasteAction: visibleEntryActions.includes("paste")
    readonly property bool showPinAction: visibleEntryActions.includes("pin")
    readonly property bool showEditAction: visibleEntryActions.includes("edit")
    readonly property bool showDeleteAction: visibleEntryActions.includes("delete")
    readonly property bool showPinnedIndicator: hasPinnedDuplicate && !showPinAction
    // Image entries (screenshots etc.) can be opened in the default viewer.
    readonly property bool showOpenAction: entryType === "image" && !!entry.path
    readonly property bool showAnyAction: showCopyAction || showPasteAction || showPinAction || showEditAction || showDeleteAction || showPinnedIndicator || showOpenAction

    // Rows fit their content: a one-line text entry stays at the compact minimum,
    // a long entry reserves room for previewMaxLines. This is derived from the line
    // metric and the *maximum* line count (a per-type constant), NOT the measured
    // content, so the height is final the instant the delegate is created. If it
    // depended on the preview Text growing after layout, the ListView would place
    // the next row against the delegate's initial (short) height and never reflow,
    // leaving long entries overlapping their neighbour. The +1 covers the header
    // line above the preview.
    implicitHeight: Math.max(ClipboardConstants.itemHeight, (root.previewMaxLines + 1) * fmPreview.lineSpacing + Theme.spacingXS + Theme.spacingM * 2)

    radius: Theme.cornerRadius
    color: {
        if (isSelected) {
            return Theme.primaryPressed;
        }
        return mouseArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency);
    }

    VgsRipple {
        id: rippleLayer
        rippleColor: Theme.surfaceText
        cornerRadius: root.radius
    }

    // Line metric for the preview font, used to reserve a deterministic row height
    // (see implicitHeight) without waiting on the preview Text to lay out.
    FontMetrics {
        id: fmPreview
        font: previewText.font
    }

    Row {
        id: actionButtons
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS
        visible: root.showAnyAction

        Item {
            width: 40
            height: 40
            visible: root.showPinnedIndicator

            // Status indicator only; the Pin action remains hidden.
            VgsIcon {
                anchors.centerIn: parent
                name: "push_pin"
                size: Theme.iconSize - 6
                color: Theme.primary
            }
        }

        VgsActionButton {
            iconName: "open_in_new"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceText
            visible: root.showOpenAction
            onClicked: ClipboardService.openEntry(entry)
        }

        VgsActionButton {
            iconName: "content_copy"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceText
            visible: root.showCopyAction
            onClicked: copyRequested()
        }

        VgsActionButton {
            iconName: "content_paste"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceText
            visible: root.showPasteAction
            onClicked: pasteRequested()
        }

        VgsActionButton {
            iconName: "push_pin"
            iconSize: Theme.iconSize - 6
            iconColor: (entry.pinned || hasPinnedDuplicate) ? Theme.primary : Theme.surfaceText
            backgroundColor: (entry.pinned || hasPinnedDuplicate) ? Theme.primarySelected : Theme.withAlpha(Theme.primarySelected, 0)
            visible: root.showPinAction
            onClicked: {
                if (entry.pinned) {
                    unpinRequested(entry);
                    return;
                }
                if (pinnedDuplicateEntry) {
                    unpinRequested(pinnedDuplicateEntry);
                    return;
                }
                pinRequested(entry);
            }
        }

        VgsActionButton {
            iconName: "edit"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceText
            visible: root.showEditAction

            onClicked: {
                if (entryType === "image") {
                    return;
                }
                editRequested();
            }
        }

        VgsActionButton {
            iconName: "close"
            iconSize: Theme.iconSize - 6
            iconColor: Theme.surfaceText
            visible: root.showDeleteAction
            onClicked: deleteRequested()
        }
    }

    Item {
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.right: root.showAnyAction ? actionButtons.left : parent.right
        anchors.rightMargin: root.showAnyAction ? Theme.spacingM : Theme.spacingS
        // Fill the row vertically rather than clip to an exact measured height:
        // the row's implicitHeight already reserves the content height plus
        // symmetric padding, and text can paint a hair past its measured
        // implicitHeight, so a tight clip here shaved the last line's descenders.
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        // Image entries show their thumbnail; text entries carry no leading
        // icon so the text spans the full row.
        ClipboardThumbnail {
            id: thumbnail
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: entryType === "image"
            width: entryType === "image" ? ClipboardConstants.thumbnailSize : 0
            height: entryType === "image" ? ClipboardConstants.itemHeight - 4 : 0
            entry: root.entry
            entryType: root.entryType
            modal: root.modal
            listView: root.listView
            itemIndex: root.itemIndex
        }

        Column {
            id: contentColumn
            anchors.left: thumbnail.right
            anchors.leftMargin: entryType === "image" ? Theme.spacingM : 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            StyledText {
                text: {
                    switch (entryType) {
                    case "image":
                        return I18n.tr("Image") + " • " + entryPreview;
                    case "long_text":
                        return I18n.tr("Long Text");
                    default:
                        return I18n.tr("Text");
                    }
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.primary
                font.weight: Font.Medium
                width: parent.width
                elide: Text.ElideRight
            }

            StyledText {
                id: previewText
                text: entryPreview
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                width: parent.width
                // Wrap at word boundaries, but break mid-token when a "word" is
                // longer than the row (e.g. a no-space link/URL). Plain WordWrap
                // refuses to break such tokens and lays them on one line at their
                // full natural width — painting over the action buttons and the
                // neighbouring entry. Text.Wrap keeps them inside the container.
                wrapMode: Text.Wrap
                maximumLineCount: root.previewMaxLines
                // Single-line previews elide with a trailing ellipsis. Multi-line
                // previews must NOT elide: an elided, wrapped, line-capped Text
                // reports an unreliable implicitHeight, which let long entries
                // overflow into the next row.
                elide: root.previewMaxLines > 1 ? Text.ElideNone : Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.left: parent.left
        anchors.right: root.showAnyAction ? actionButtons.left : parent.right
        anchors.rightMargin: root.showAnyAction ? Theme.spacingS : 0
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onPressed: mouse => {
            if (mouse.button === Qt.LeftButton) {
                const pos = mouseArea.mapToItem(root, mouse.x, mouse.y);
                rippleLayer.trigger(pos.x, pos.y);
            }
        }
        onClicked: {
            if (SettingsData.clipboardClickToPaste) {
                pasteRequested();
            } else {
                copyRequested();
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => {
            const scenePos = mapToItem(null, mouse.x, mouse.y);
            contextMenuRequested(scenePos.x, scenePos.y);
        }
    }
}
