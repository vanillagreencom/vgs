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
// selection seeding. A subclass binds `activeKey`.
//
// The base's own per-open reset runs from a self-targeted `Connections` rather
// than a root-level `onOpened:`, because a derived `onOpened:` REPLACES an
// inline base handler and would silently take the reset with it. A `Connections`
// handler coexists with any a subclass declares.
//
// A subclass MUST also override `layerNamespace` with a "vshell:"-prefixed name
// whose derived IPC target VGSIPC.qml registers, and it MUST live in this
// directory. `switcher_check` (scripts/qml-smoke.sh) finds subclasses by their
// ROOT ELEMENT across the whole QML tree — not by filename — and FAILS on one
// that breaks any of those three, so the coverage is not left to this comment
// being read. The default below exists only to keep an unregistered switcher off
// the shared "vshell:modal" surface.
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
    // Set when the list on screen could not be refreshed but the previous one is
    // still browsable. Shown as a banner, NOT as the empty state: dropping a
    // working list because a refresh failed destroys a usable browse, and
    // showing it silently as if it were fresh is the dishonesty this replaces.
    property string staleNotice: ""

    property string filterQuery: ""
    property int currentIndex: 0
    property bool applyBlocked: false
    // The latch is USER INTENT, not data arrival. Both services answer
    // asynchronously and both `show()` paths dispatch their read and `open()` in
    // the same tick, so the list present at open is by construction the PREVIOUS
    // one; `activeKey` can also land after it. Until the user has moved the
    // selection, every new list and every new `activeKey` re-seeds, so the
    // switcher ends up on the entry actually in use. Once they have moved,
    // nothing re-seeds — a background reload must not snap the selection off
    // what they paged to, because Enter at that moment applies the wrong entry.
    property bool userMoved: false

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

    // BEGIN SWITCHER SELECTION DECISION
    // The selection arithmetic, taking every input as an argument so
    // scripts/test-switcher-selection.js can execute it. Nothing here may
    // reference `root`, `Theme`, `I18n` or `Qt` — the extraction has to be the
    // same program the shell runs. Parameter names deliberately differ from the
    // properties they are passed, so nothing here can read a property by
    // accident if an argument is ever dropped at a call site.
    function wrapIndex(index, count) {
        if (count <= 0)
            return 0;
        // Wrap: a single-item pager has no visible list edge to explain a dead
        // arrow key, so running off one end lands on the other.
        return ((index % count) + count) % count;
    }

    // A reload can reshape the list under the selection without changing its
    // length, so the index is re-clamped on every list change.
    function clampIndex(index, count) {
        if (count <= 0)
            return 0;
        if (index >= count)
            return count - 1;
        if (index < 0)
            return 0;
        return index;
    }

    // Where a fresh list should open: the entry already in use, or the top when
    // it is not in this list (a filtered-out or removed entry).
    function seedIndex(list, wantedKey) {
        const entries = list || [];
        for (let i = 0; i < entries.length; i++) {
            if (entries[i].key === wantedKey)
                return i;
        }
        return 0;
    }

    // Re-seed only while the surface is up and the user has not taken over the
    // selection. Seeding a hidden surface would fight its next open.
    function shouldReseed(surfaceVisible, moved) {
        return !!surfaceVisible && !moved;
    }

    // What Enter does: "none" when there is nothing selected, "blocked" when an
    // apply is already running (the surface stays up and says so), "apply"
    // otherwise.
    function enterOutcome(applyAllowed, entry) {
        if (!entry)
            return "none";
        return applyAllowed ? "apply" : "blocked";
    }

    // Whether a PAGING input takes the selection over: only when there was
    // something to move to.
    //
    // Both `show()` paths dispatch their read and `open()` in the same tick, so
    // there is a window at every open where the list is empty — guaranteed on the
    // first wallpaper-switcher open of a session. Home or End pressed in that
    // window used to latch against nothing, and every later re-seed then found
    // the latch already set: the switcher sat on index 0 for the whole open
    // instead of landing on the entry in use, while the arrow keys answered the
    // opposite for the same empty list.
    function latchesIntent(count) {
        return count > 0;
    }

    // Where a paging input lands: "step" moves by `delta` and wraps, "first" and
    // "last" go to the ends. Only meaningful once `latchesIntent` said the input
    // acts.
    function navIndex(kind, index, count, delta) {
        if (count <= 0)
            return 0;
        if (kind === "first")
            return 0;
        if (kind === "last")
            return clampIndex(count - 1, count);
        return wrapIndex(index + delta, count);
    }
    // END SWITCHER SELECTION DECISION

    // The one adapter every paging key goes through, so the latch and the target
    // are decided once, in the region above, for all of them.
    function navigate(kind, delta) {
        if (!root.latchesIntent(root.itemCount))
            return;
        root.userMoved = true;
        root.currentIndex = root.navIndex(kind, root.currentIndex, root.itemCount, delta);
    }

    function step(delta) {
        root.navigate("step", delta);
    }

    // The image `delta` steps away, for the lookahead below.
    function neighborUrl(delta) {
        if (itemCount < 2)
            return "";
        const entry = visibleItems[wrapIndex(currentIndex + delta, itemCount)];
        return entry ? fileUrl(entry.image) : "";
    }

    function seedSelection() {
        root.currentIndex = root.seedIndex(root.visibleItems, root.activeKey);
    }

    function reseedIfUntouched() {
        if (root.shouldReseed(root.shouldBeVisible, root.userMoved))
            root.seedSelection();
    }

    function applyCurrent() {
        const outcome = root.enterOutcome(root.canApply, root.currentItem);
        if (outcome === "none")
            return;
        if (outcome === "blocked") {
            root.applyBlocked = true;
            applyBlockedTimer.restart();
            return;
        }
        root.applyBlocked = false;
        root.applied(root.currentItem);
        root.close();
    }

    // Upper bound only. The footer tells the user to wait for the apply to
    // finish, so `onCanApplyChanged` is what normally clears the message; this
    // stops it sticking forever behind a service that never goes idle.
    Timer {
        id: applyBlockedTimer
        interval: 2500
        onTriggered: root.applyBlocked = false
    }

    onCanApplyChanged: {
        if (!canApply)
            return;
        applyBlocked = false;
        applyBlockedTimer.stop();
    }

    onVisibleItemsChanged: {
        currentIndex = clampIndex(currentIndex, itemCount);
        reseedIfUntouched();
    }

    // `activeKey` is read asynchronously too (`theme current --json`), and can
    // land either side of the list. Both edges re-seed, so whichever arrives
    // last is the one the selection ends up on.
    onActiveKeyChanged: reseedIfUntouched()

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
            root.navigate("first", 0);
            return true;
        }
        if (event.key === Qt.Key_End) {
            root.navigate("last", 0);
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
    // stops `closeTimer`, so `dialogClosed` never fires — reset on open as well
    // or the surface returns with the last filter and selection still on it.
    Connections {
        target: root

        function onOpened() {
            root.filterQuery = "";
            root.applyBlocked = false;
            root.userMoved = false;
            root.seedSelection();
        }

        function onDialogClosed() {
            root.filterQuery = "";
            root.currentIndex = 0;
            root.applyBlocked = false;
            root.userMoved = false;
        }
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
                    onTextEdited: {
                        // Typing IS taking over the selection, with or without a
                        // list on screen: the filter is what the user is steering
                        // by, and without this a list landing after they clear it
                        // would re-seed and jump off whatever they were looking
                        // at. Unconditional, unlike the paging keys, which must
                        // not latch against an empty pager.
                        root.userMoved = true;
                        root.filterQuery = text;
                    }
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    // Only over a list there is something to browse; with none,
                    // the empty state already carries the failure.
                    visible: root.staleNotice !== "" && root.itemCount > 0
                    text: root.staleNotice
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.warning
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
                    text: root.applyBlocked ? I18n.tr("Still applying — press Enter again in a moment") : I18n.tr("Arrow keys page · Enter applies · Esc cancels")
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
