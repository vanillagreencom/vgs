pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Widgets

// Full-screen one-at-a-time picker: a single large preview image, paged with the
// arrow keys, applied with Enter, abandoned with Esc.
//
// Paging only moves the selection. Nothing is applied while the user browses, so
// an Esc really does leave the desktop exactly as it was; the wallpaper and theme
// switchers both rely on that and neither previews live.
//
// Callers supply a normalized `items` list and handle `applied`; this file owns
// the surface, the paging, the optional filter and the key handling.
VgsModal {
    id: root

    // [{image: absolute path, label: caption, badge: short tag or "", key: apply id}]
    property var items: []
    // Type-to-filter (theme switcher); the wallpaper switcher has no filter.
    property bool filterable: false
    property string filterPlaceholder: ""
    property string emptyText: I18n.tr("Nothing to show")
    property string headerTitle: ""
    property string headerIcon: ""

    property string filterQuery: ""
    property int currentIndex: 0

    signal applied(var item)

    // Simple word match: every whitespace-separated term must appear in the
    // label. That is what the label is — a theme name — so no fuzzy ranking.
    readonly property var visibleItems: {
        const list = root.items || [];
        if (!root.filterable)
            return list;
        const terms = root.filterQuery.trim().toLowerCase().split(/\s+/).filter(t => t.length > 0);
        if (terms.length === 0)
            return list;
        return list.filter(entry => {
            const label = String(entry.label || "").toLowerCase();
            return terms.every(term => label.includes(term));
        });
    }

    readonly property int itemCount: (visibleItems || []).length
    readonly property var currentItem: (currentIndex >= 0 && currentIndex < itemCount) ? visibleItems[currentIndex] : null

    // Wallpaper filenames are user data and routinely carry spaces, '#' and '%',
    // all of which break a raw file:// URL. Encode per segment, as CachingImage
    // does, so the separators survive.
    function fileUrl(path) {
        if (!path)
            return "";
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
    }

    function step(delta) {
        if (itemCount === 0)
            return;
        // Wrap: a single-item pager has no visible list edge to explain a dead
        // arrow key, so running off one end lands on the other.
        currentIndex = ((currentIndex + delta) % itemCount + itemCount) % itemCount;
    }

    function applyCurrent() {
        const entry = root.currentItem;
        if (!entry)
            return;
        root.applied(entry);
        root.close();
    }

    // Filtering can shorten the list under the selection; keep it in range and
    // never leave it pointing past the end.
    onItemCountChanged: {
        if (currentIndex >= itemCount)
            currentIndex = Math.max(0, itemCount - 1);
    }

    function handleKey(event) {
        if (event.key === Qt.Key_Escape) {
            root.close();
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.applyCurrent();
            return true;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            return true;
        }
        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            return true;
        }
        if (event.key === Qt.Key_Home) {
            root.currentIndex = 0;
            return true;
        }
        if (event.key === Qt.Key_End) {
            root.currentIndex = Math.max(0, root.itemCount - 1);
            return true;
        }
        return false;
    }

    layerNamespace: "vshell:switcher"
    shouldBeVisible: false
    allowStacking: false
    modalWidth: screenWidth
    modalHeight: screenHeight
    // Full-bleed: no rounding, no shadow, and no slide offset — a non-zero
    // animation offset pads the layer surface past the screen edge.
    cornerRadius: 0
    enableShadow: false
    animationOffset: 0
    backgroundColor: Theme.popupSurfaceColor(Theme.background)
    closeOnBackgroundClick: false

    onDialogClosed: {
        filterQuery = "";
        currentIndex = 0;
    }

    content: Component {
        FocusScope {
            id: switcherContent
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (root.handleKey(event))
                    event.accepted = true;
            }

            Component.onCompleted: {
                // The filter field takes focus when there is one so typing filters
                // immediately; otherwise the pager itself holds the keys.
                Qt.callLater(() => {
                    if (root.filterable)
                        filterField.forceActiveFocus();
                    else
                        switcherContent.forceActiveFocus();
                });
            }

            Column {
                id: headerBlock
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingXL
                spacing: Theme.spacingL

                Item {
                    width: parent.width
                    height: headerRow.implicitHeight

                    Row {
                        id: headerRow
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: root.headerIcon
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.headerIcon !== ""
                        }

                        StyledText {
                            text: root.headerTitle
                            font.pixelSize: Theme.fontSizeXLarge
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.itemCount > 0 ? `${root.currentIndex + 1} / ${root.itemCount}` : "0 / 0"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                    }
                }

                VgsTextField {
                    id: filterField
                    visible: root.filterable
                    height: 40
                    width: Math.min(parent.width, 520)
                    anchors.horizontalCenter: parent.horizontalCenter
                    placeholderText: root.filterPlaceholder
                    backgroundColor: Theme.surfaceContainerHigh
                    leftIconName: "search"
                    enabled: root.shouldBeVisible && root.filterable
                    // The pager owns every navigation key; the field only types.
                    ignoreLeftRightKeys: true
                    ignoreTabKeys: true
                    onTextEdited: root.filterQuery = text

                    Keys.onPressed: event => {
                        if (root.handleKey(event))
                            event.accepted = true;
                    }

                    Connections {
                        target: root
                        function onDialogClosed() {
                            // `text` was written by typing, which replaced any
                            // binding to filterQuery — clear it explicitly.
                            filterField.text = "";
                        }
                    }
                }
            }

            Column {
                id: footerBlock
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingXL
                spacing: Theme.spacingS

                Item {
                    width: parent.width
                    height: captionRow.implicitHeight

                    Row {
                        id: captionRow
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.spacingS

                        StyledText {
                            text: root.currentItem ? root.currentItem.label : ""
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Rectangle {
                            visible: !!(root.currentItem && root.currentItem.badge)
                            anchors.verticalCenter: parent.verticalCenter
                            width: badgeLabel.implicitWidth + Theme.spacingS * 2
                            height: badgeLabel.implicitHeight + Theme.spacingXS * 2
                            radius: Theme.controlRadius
                            color: Theme.primary

                            StyledText {
                                id: badgeLabel
                                anchors.centerIn: parent
                                text: root.currentItem ? (root.currentItem.badge || "") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.primaryText
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: I18n.tr("Arrow keys page · Enter applies · Esc cancels")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            Item {
                id: stage
                anchors.top: headerBlock.bottom
                anchors.bottom: footerBlock.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                anchors.leftMargin: Theme.spacingXL
                anchors.rightMargin: Theme.spacingXL

                Image {
                    id: preview
                    anchors.fill: parent
                    visible: root.itemCount > 0 && status === Image.Ready
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectFit
                    // Decode at display size: theme previews are 1920x1080 but a
                    // user wallpaper can be far larger than the screen.
                    sourceSize.width: Math.max(1, Math.round(stage.width * root.dpr))
                    sourceSize.height: Math.max(1, Math.round(stage.height * root.dpr))
                    source: root.currentItem ? root.fileUrl(root.currentItem.image) : ""
                }

                VgsSpinner {
                    anchors.centerIn: parent
                    visible: root.itemCount > 0 && preview.status === Image.Loading
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: root.itemCount === 0
                    text: root.emptyText
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: root.itemCount > 0 && preview.status !== Image.Ready && preview.status !== Image.Loading
                    text: I18n.tr("Preview unavailable")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
