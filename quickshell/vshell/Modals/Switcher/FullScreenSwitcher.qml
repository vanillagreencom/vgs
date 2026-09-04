pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Widgets

// Full-screen picker with arrow-key paging and explicit apply. Browsing alone does not change the desktop.
// The carousel geometry follows the Omarchy image picker. Subclasses supply activeKey and an IPC-registered vshell: namespace.
// Keep subclasses in this directory for switcher_check in scripts/qml-smoke.sh.
// Use self-targeted Connections for reset: a subclass inline onOpened handler replaces a base inline handler.
VgsModal {
    id: root

    // [{image: absolute path, label: caption, key: apply id}]
    property var items: []
    // Type-to-filter (theme switcher); the wallpaper switcher has no filter.
    property bool filterable: false
    // Whether to show the selected entry label below the carousel.
    property bool showLabels: true
    property string emptyText: I18n.tr("Nothing to show")
    // The entry already in use: what the selection is seeded to on open.
    property string activeKey: ""
    // False while the owning service cannot accept an apply. Enter then keeps the
    // surface up and says so, instead of dismissing it with nothing applied.
    property bool canApply: true
    // Report a failed refresh while retaining a usable list; the empty-state message is only for an empty list.
    property string staleNotice: ""
    // Optional scope control above the rail. Its presence also assigns Tab to scope selection instead of paging.
    property Component scopeToggle: null
    // Scope changes do not latch selection intent; reseeding must still select the entry active in the new scope.
    signal scopeFlipRequested

    property string filterQuery: ""
    property int currentIndex: 0
    property bool applyBlocked: false
    // Reseed from late list and activeKey replies until the user moves selection.
    // After user input, background replies must not change what Enter applies.
    property bool userMoved: false
    // Carry fractional wheel movement across events; reset between opens so it cannot move a later session.
    property real wheelAccumulator: 0
    // Preserve selected identity by key when a list change moves its index.
    property string selectedKey: ""

    signal applied(var item)

    // Match every whitespace-separated filter term within the label.
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

    // BEGIN SWITCHER SELECTION DECISION
    // Keep selection decisions independent of QML properties so the runtime and extracted tests use the same inputs.
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-switcher-selection.js extracts and executes it as the same program the shell runs.
    function wrapIndex(index, count) {
        if (count <= 0)
            return 0;
        // Wrap at either end because this pager has no visible list edge.
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

    // Paging takes selection ownership only when the list has an entry.
    // Input while the initial read is pending must not prevent reseeding when the reply arrives.
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
    // Preserve the selected key across filtering; clamping its old index alone can select a different entry after the filter clears.
    function preserveIndex(list, wantedKey, index) {
        const entries = list || [];
        if (entries.length <= 0)
            return 0;
        if (wantedKey) {
            for (let i = 0; i < entries.length; i++) {
                if (entries[i].key === wantedKey)
                    return i;
            }
        }
        return clampIndex(index, entries.length);
    }

    // Return whole wheel steps and the fractional remainder. Preserve sub-notch movement for the next event.
    function wheelSteps(accumulated, notch) {
        if (!notch || notch <= 0)
            return {
                steps: 0,
                remainder: 0
            };
        const steps = Math.trunc(accumulated / notch);
        return {
            steps: steps,
            remainder: accumulated - steps * notch
        };
    }
    // END SWITCHER SELECTION DECISION

    // Share intent latching and target calculation across paging keys.
    function navigate(kind, delta) {
        if (!root.latchesIntent(root.itemCount))
            return;
        root.userMoved = true;
        root.currentIndex = root.navIndex(kind, root.currentIndex, root.itemCount, delta);
        root.holdCurrent();
    }

    // Save the selected key after movement so list replacement can preserve it.
    function holdCurrent() {
        // An empty filter result must not clear the held key. Backspacing can restore that entry; open/close reset the key separately.
        if (root.currentItem)
            root.selectedKey = String(root.currentItem.key || "");
    }

    function step(delta) {
        root.navigate("step", delta);
    }

    // Use the same paging rules for wheel and keyboard input.
    function pageByWheel(deltaY, deltaX) {
        const delta = deltaY !== 0 ? deltaY : deltaX;
        if (delta === 0)
            return;
        root.wheelAccumulator += delta;
        const outcome = root.wheelSteps(root.wheelAccumulator, 120);
        root.wheelAccumulator = outcome.remainder;
        if (outcome.steps === 0)
            return;

        root.step(-outcome.steps);
    }

    // Typing latches selection intent even when the list is empty, so late replies cannot reset the filtered selection.
    function updateFilter(nextQuery) {
        root.userMoved = true;
        root.filterQuery = nextQuery;
    }

    // Decode filter input here because the caption has no TextInput. Leave Alt/Meta sequences for other shortcuts.
    function editsFilter(event) {
        if (!root.filterable || !root.filterQuery)
            return false;
        if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier))
            return false;
        if (event.key === Qt.Key_U)
            // Ctrl+U only: Ctrl+Shift+U starts Unicode input.
            return event.modifiers === Qt.ControlModifier;
        return event.key === Qt.Key_Backspace;
    }

    function editedFilter(event) {
        if (event.key === Qt.Key_U)
            return "";
        if (event.modifiers & Qt.ControlModifier)
            return root.filterQuery.replace(/\s+$/, "").replace(/\S+$/, "");
        return root.filterQuery.slice(0, -1);
    }

    // Exclude control characters and DEL from printable filter text.
    function typesFilter(event) {
        if (!root.filterable || !event.text || event.text.length !== 1)
            return false;
        if (event.modifiers !== Qt.NoModifier && event.modifiers !== Qt.ShiftModifier)
            return false;
        const code = event.text.charCodeAt(0);
        return code >= 32 && code !== 127;
    }

    function seedSelection() {
        root.currentIndex = root.seedIndex(root.visibleItems, root.activeKey);
        root.holdCurrent();
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

    // Clear the blocked-apply message on completion; use this timeout if the service never returns idle.
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
        currentIndex = preserveIndex(visibleItems, selectedKey, currentIndex);
        reseedIfUntouched();
        holdCurrent();
    }

    // List and activeKey arrive independently. Retry seeding on either update until the user takes selection ownership.
    onActiveKeyChanged: reseedIfUntouched()

    function handleKey(event) {
        if (event.key === Qt.Key_Escape) {
            // A filter is the first thing Esc takes back, so a mistyped term
            // does not cost the whole browse.
            if (root.filterable && root.filterQuery)
                root.updateFilter("");
            else
                root.close();
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.applyCurrent();
            return true;
        }
        if (root.editsFilter(event)) {
            root.updateFilter(root.editedFilter(event));
            return true;
        }
        // With a scope control, Tab and Backtab change scope. Other paging keys still move the selection.
        if (root.scopeToggle && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
            root.scopeFlipRequested();
            return true;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
            root.step(-1);
            return true;
        }
        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
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
        if (root.typesFilter(event)) {
            root.updateFilter(root.filterQuery + event.text);
            return true;
        }
        return false;
    }

    layerNamespace: "vshell:switcher"
    shouldBeVisible: false
    allowStacking: false
    modalWidth: screenWidth
    modalHeight: screenHeight
    // Full-screen geometry needs zero animation offset so surface padding cannot extend past output edges.
    cornerRadius: 0
    enableShadow: false

    enableBorder: false
    animationOffset: 0
    // Use a separate scrim alpha so an opaque popup preference cannot hide the desktop under this picker.
    backgroundColor: Theme.withAlpha(Theme.background, 0.5)
    // Disable the base backdrop opacity to avoid double dimming. Keep showBackground true so the click-catcher surface and the smoke paths that drive it are unchanged.
    backgroundOpacity: 0
    closeOnBackgroundClick: false

    // Reopening cancels closeTimer before dialogClosed. Reset on open so a retained Loader cannot keep the old filter and selection.
    Connections {
        target: root

        function onOpened() {
            root.filterQuery = "";
            root.applyBlocked = false;
            root.userMoved = false;
            root.wheelAccumulator = 0;
            root.selectedKey = "";
            root.seedSelection();
        }

        function onDialogClosed() {
            root.filterQuery = "";
            root.currentIndex = 0;
            root.applyBlocked = false;
            root.userMoved = false;
            root.wheelAccumulator = 0;
            root.selectedKey = "";
        }
    }

    content: Component {
        FocusScope {
            id: switcherContent
            anchors.fill: parent
            focus: true

            readonly property real gutter: Theme.spacingXL
            readonly property real availableWidth: width - gutter * 2
            readonly property real availableHeight: height - gutter * 2 - captions.height - Theme.spacingL - scopeReserve
            readonly property real scopeReserve: scopeSlot.height > 0 ? scopeSlot.height + Theme.spacingL : 0
            // Scale captions from width, not railScale: caption height contributes to railScale and would create a binding loop.
            readonly property real captionScale: Math.max(1, Math.min(2, switcherContent.availableWidth / carousel.baseRailWidth))
            readonly property real railScale: {
                const byWidth = switcherContent.availableWidth / carousel.baseRailWidth;
                const byHeight = switcherContent.availableHeight / 475;
                return Math.max(0.35, Math.min(2, Math.min(byWidth, byHeight)));
            }

            Keys.onPressed: event => {
                if (root.handleKey(event))
                    event.accepted = true;
            }

            Component.onCompleted: forceActiveFocus()

            Connections {
                target: root
                // Reopening during close retains this tree, so reclaim keyboard focus explicitly.
                function onOpened() {
                    switcherContent.forceActiveFocus();
                }
            }


            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }


            WheelHandler {
                target: null
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => root.pageByWheel(event.angleDelta.y, event.angleDelta.x)
            }

            SwitcherCarousel {
                id: carousel
                width: carousel.baseRailWidth * switcherContent.railScale
                height: 475 * switcherContent.railScale
                anchors.horizontalCenter: parent.horizontalCenter
                y: (switcherContent.height - height - Theme.spacingL - captions.height + switcherContent.scopeReserve) / 2
                visible: root.itemCount > 0

                dpr: root.dpr
                items: root.visibleItems
                selectedIndex: root.currentIndex
                onPicked: index => {
                    root.userMoved = true;
                    root.currentIndex = index;
                    root.holdCurrent();
                }
                onActivated: root.applyCurrent()
            }

            StyledText {
                anchors.centerIn: carousel
                width: Math.min(parent.width - switcherContent.gutter * 2, 720)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: root.itemCount === 0
                text: root.emptyText
                font.pixelSize: Theme.fontSizeLarge * switcherContent.captionScale
                color: Theme.surfaceText
                style: Text.Outline
                styleColor: Theme.withAlpha(Theme.background, 0.7)
            }


            Column {
                id: captions
                anchors.top: carousel.bottom
                anchors.topMargin: Theme.spacingL
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    visible: root.showLabels
                    text: root.currentItem ? root.currentItem.label : ""
                    font.pixelSize: Theme.fontSizeXLarge * switcherContent.captionScale
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                    style: Text.Outline
                    styleColor: Theme.withAlpha(Theme.background, 0.7)
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    visible: root.filterable && root.filterQuery !== ""
                    text: root.filterQuery
                    opacity: 0.85
                    font.pixelSize: Theme.fontSizeLarge * switcherContent.captionScale
                    color: Theme.surfaceText
                    style: Text.Outline
                    styleColor: Theme.withAlpha(Theme.background, 0.7)
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    // A stale-list notice requires a browsable list; the empty state carries failures when no entries remain.
                    visible: text !== ""
                    text: {
                        if (root.applyBlocked)
                            return I18n.tr("Still applying — press Enter again in a moment");
                        if (root.staleNotice !== "" && root.itemCount > 0)
                            return root.staleNotice;
                        return "";
                    }
                    font.pixelSize: Theme.fontSizeSmall * switcherContent.captionScale
                    color: root.applyBlocked ? Theme.primary : Theme.warning
                    style: Text.Outline
                    styleColor: Theme.withAlpha(Theme.background, 0.7)
                }
            }

            // Declare the scope control after the click-away area so control clicks cannot dismiss the surface.
            Loader {
                id: scopeSlot
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: carousel.top
                anchors.bottomMargin: Theme.spacingL
                sourceComponent: root.scopeToggle
                // Size the pill directly: transforming NativeRendering text scales rasterized glyphs and blurs them.
            }
        }
    }
}
