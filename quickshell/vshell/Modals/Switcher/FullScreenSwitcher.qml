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
// the surface, the paging, the optional filter, the key handling and the
// selection seeding. A subclass binds `activeKey` and must NOT declare its own
// `onOpened` — a derived handler REPLACES the base's, and the seeding with it.
//
// A subclass MUST also override `layerNamespace` and register that namespace in
// `switcher_check` (scripts/qml-smoke.sh); the default below exists only to keep
// an unregistered switcher off the shared "vshell:modal" surface.
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
    // The entry already in use: what the selection is seeded to on open.
    property string activeKey: ""
    // False while the owning service cannot accept an apply. Enter then keeps the
    // surface up and says so, instead of dismissing it with nothing applied.
    property bool canApply: true

    property string filterQuery: ""
    property int currentIndex: 0
    property bool applyBlocked: false
    // Seeding is ONCE per open. Both services re-emit their loaded signals while
    // the surface is up (background preview generation, wallpaper adds), and
    // re-seeding then snaps the selection off whatever the user paged to — Enter
    // at that moment applies the wrong entry.
    property bool seeded: false

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

    function wrapIndex(index) {
        if (itemCount === 0)
            return 0;
        // Wrap: a single-item pager has no visible list edge to explain a dead
        // arrow key, so running off one end lands on the other.
        return ((index % itemCount) + itemCount) % itemCount;
    }

    function step(delta) {
        if (itemCount === 0)
            return;
        currentIndex = wrapIndex(currentIndex + delta);
    }

    // The image `delta` steps away, for the lookahead below.
    function neighborUrl(delta) {
        if (itemCount < 2)
            return "";
        const entry = visibleItems[wrapIndex(currentIndex + delta)];
        return entry ? fileUrl(entry.image) : "";
    }

    function seedSelection() {
        const list = root.visibleItems || [];
        let index = 0;
        for (let i = 0; i < list.length; i++) {
            if (list[i].key === root.activeKey) {
                index = i;
                break;
            }
        }
        root.currentIndex = index;
        // An empty list is not a seed: the services answer asynchronously, so the
        // first list is routinely empty and the real one arrives after open().
        if (list.length > 0)
            root.seeded = true;
    }

    function applyCurrent() {
        const entry = root.currentItem;
        if (!entry)
            return;
        if (!root.canApply) {
            root.applyBlocked = true;
            applyBlockedTimer.restart();
            return;
        }
        root.applyBlocked = false;
        root.applied(entry);
        root.close();
    }

    Timer {
        id: applyBlockedTimer
        interval: 2500
        onTriggered: root.applyBlocked = false
    }

    // Filtering and reloads both reshape the list under the selection: keep the
    // index in range (the count alone can be unchanged while the entries are
    // not), and take the first non-empty list as the seed.
    onVisibleItemsChanged: {
        if (currentIndex >= itemCount)
            currentIndex = Math.max(0, itemCount - 1);
        if (currentIndex < 0)
            currentIndex = 0;
        if (shouldBeVisible && !seeded && filterQuery === "")
            seedSelection();
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

    // Reopening inside the close animation keeps the content Loader alive and
    // stops `closeTimer`, so `dialogClosed` never fires — reset here as well or
    // the surface returns with the last filter and selection still on it.
    onOpened: {
        filterQuery = "";
        applyBlocked = false;
        seeded = false;
        seedSelection();
    }

    onDialogClosed: {
        filterQuery = "";
        currentIndex = 0;
        applyBlocked = false;
        seeded = false;
    }

    content: Component {
        FocusScope {
            id: switcherContent
            anchors.fill: parent
            focus: true

            // The filter field takes focus when there is one so typing filters
            // immediately; otherwise the pager itself holds the keys.
            function claimFocus() {
                Qt.callLater(() => {
                    if (root.filterable)
                        filterField.forceActiveFocus();
                    else
                        switcherContent.forceActiveFocus();
                });
            }

            Keys.onPressed: event => {
                if (root.handleKey(event))
                    event.accepted = true;
            }

            Component.onCompleted: claimFocus()

            Connections {
                target: root
                // A reopen inside the close animation does not rebuild this tree,
                // so nothing else would re-claim the keys.
                function onOpened() {
                    filterField.text = "";
                    switcherContent.claimFocus();
                }
                function onDialogClosed() {
                    // `text` was written by typing, which replaced any binding to
                    // filterQuery — clear it explicitly.
                    filterField.text = "";
                }
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
                    // `ignoreLeftRightKeys` alone SWALLOWS Left/Right — the flag
                    // only forwards through `keyForwardTargets`, which is also
                    // what gets Home/End past the TextInput's cursor handling.
                    ignoreLeftRightKeys: true
                    ignoreTabKeys: true
                    keyForwardTargets: [switcherContent]
                    onTextEdited: root.filterQuery = text
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
                    text: root.applyBlocked ? I18n.tr("Still loading — press Enter again in a moment") : I18n.tr("Arrow keys page · Enter applies · Esc cancels")
                    font.pixelSize: Theme.fontSizeSmall
                    color: root.applyBlocked ? Theme.primary : Theme.surfaceVariantText
                }
            }

            SwitcherStage {
                anchors.top: headerBlock.bottom
                anchors.bottom: footerBlock.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                anchors.leftMargin: Theme.spacingXL
                anchors.rightMargin: Theme.spacingXL

                dpr: root.dpr
                hasItems: root.itemCount > 0
                emptyText: root.emptyText
                imageSource: root.currentItem ? root.fileUrl(root.currentItem.image) : ""
                prefetchSources: [root.neighborUrl(-1), root.neighborUrl(1)]
            }
        }
    }
}
