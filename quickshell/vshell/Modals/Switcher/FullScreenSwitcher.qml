pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Widgets

// Full-screen one-at-a-time picker: a rail of leaning shots over a dimmed
// desktop, paged with the arrow keys, applied with Enter, abandoned with Esc.
// The look is Omarchy 4's image picker — see SwitcherCarousel.qml, which owns
// the geometry. This file owns the surface, the paging, the optional filter,
// the key handling and the selection seeding; a subclass binds `activeKey`.
//
// There is no header, no counter, no input box and no footer: the only things
// on screen besides the rail are the selected entry's name and whatever the
// user has typed. Every state that needs words (empty, stale, still applying)
// is drawn in that same caption slot, outlined against the wallpaper rather
// than boxed.
//
// Paging only moves the selection. Nothing is applied while the user browses, so
// an Esc really does leave the desktop exactly as it was; the wallpaper and theme
// switchers both rely on that and neither previews live.
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

    // [{image: absolute path, label: caption, key: apply id}]
    property var items: []
    // Type-to-filter (theme switcher); the wallpaper switcher has no filter.
    property bool filterable: false
    // Whether the selected entry is named under the rail. A theme name is worth
    // reading; a wallpaper's filename is not, and Omarchy shows neither there.
    property bool showLabels: true
    property string emptyText: I18n.tr("Nothing to show")
    // The entry already in use: what the selection is seeded to on open.
    property string activeKey: ""
    // False while the owning service cannot accept an apply. Enter then keeps the
    // surface up and says so, instead of dismissing it with nothing applied.
    property bool canApply: true
    // Set when the list on screen could not be refreshed but the previous one is
    // still browsable. Shown as a caption, NOT as the empty state: dropping a
    // working list because a refresh failed destroys a usable browse, and
    // showing it silently as if it were fresh is the dishonesty this replaces.
    property string staleNotice: ""
    // The wallpaper switcher's per-monitor scope toggle (VGS-212), loaded
    // centred just above the rail. One property is both the surface and the Tab
    // claim, so they cannot drift apart: null — the theme switcher, and any
    // single-monitor open — draws nothing and leaves Tab on paging.
    property Component scopeToggle: null
    // Emitted for Tab, Backtab and a click on the toggle; the subclass owns
    // the state it flips. Deliberately NOT a `userMoved` write: choosing a
    // scope is not taking over the selection, and the re-seed that follows
    // is how the selection lands on that scope's current entry.
    signal scopeFlipRequested

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
    // Carried between wheel events — see `wheelSteps`. Cleared with the rest of
    // the per-open state, or a half-notch left over from the last open spends
    // itself on the first scroll of the next one.
    property real wheelAccumulator: 0
    // The entry the selection is ON, by key rather than by position, so a list
    // that reshapes under it can put it back. Written wherever the selection
    // moves — see `holdCurrent`.
    property string selectedKey: ""

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
    // Where the selection lands when the LIST changes under it. The index alone
    // does not survive a filter: with B selected in [A,B,C], filtering to C
    // clamps to index 0, and CLEARING the filter then leaves index 0 pointing
    // at A — the user backspaces and their place is gone. So the KEY is what is
    // preserved, and the index is only the fallback for a key that is no longer
    // in the list at all.
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

    // How far a wheel movement pages, and what it leaves behind. One notch is
    // 120 eighths of a degree by Qt's convention, but a touchpad or a
    // high-resolution wheel sends a stream of fractions of one, so the leftover
    // is RETURNED to be carried into the next event. Rounding it away instead
    // is how a slow scroll ends up moving nothing at all.
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

    // The one adapter every paging key goes through, so the latch and the target
    // are decided once, in the region above, for all of them.
    function navigate(kind, delta) {
        if (!root.latchesIntent(root.itemCount))
            return;
        root.userMoved = true;
        root.currentIndex = root.navIndex(kind, root.currentIndex, root.itemCount, delta);
        root.holdCurrent();
    }

    // The one place the held key is written: every mover calls it after moving,
    // so the key and the index cannot disagree about what is selected.
    function holdCurrent() {
        // Only ever WRITES a key, never clears one. A query that matches
        // nothing empties the list for as long as it is typed, and clearing
        // here would throw the user's place away mid-keystroke: backspacing
        // back to a matching query would then land on the top of the list
        // rather than on the entry they were on. The per-open and per-close
        // resets are what clear it between uses.
        if (root.currentItem)
            root.selectedKey = String(root.currentItem.key || "");
    }

    function step(delta) {
        root.navigate("step", delta);
    }

    // The scroll wheel pages the rail. It goes through `step` like every other
    // paging input, so the intent latch and the empty-pager guard are the same
    // ones the keys get.
    function pageByWheel(deltaY, deltaX) {
        const delta = deltaY !== 0 ? deltaY : deltaX;
        if (delta === 0)
            return;
        root.wheelAccumulator += delta;
        const outcome = root.wheelSteps(root.wheelAccumulator, 120);
        root.wheelAccumulator = outcome.remainder;
        if (outcome.steps === 0)
            return;
        // Scrolling up or left pages BACK, which is the direction the rail
        // itself travels.
        root.step(-outcome.steps);
    }

    // The one place the filter is written. Typing IS taking over the selection,
    // with or without a list on screen: the filter is what the user is steering
    // by, and without this a list landing after they clear it would re-seed and
    // jump off whatever they were looking at. Unconditional, unlike the paging
    // keys, which must not latch against an empty pager.
    function updateFilter(nextQuery) {
        root.userMoved = true;
        root.filterQuery = nextQuery;
    }

    // There is no input box to own the filter — typing goes straight into the
    // caption under the rail, the way Omarchy's picker does — so the edit keys
    // are decoded here. Alt- and Meta-modified sequences belong to other
    // shortcuts and never edit.
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

    // A printable character, unmodified: what appends to the filter. Control
    // characters and DEL are excluded so a stray key never becomes a term no
    // entry can match.
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

    // Upper bound only. The caption tells the user to wait for the apply to
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
        currentIndex = preserveIndex(visibleItems, selectedKey, currentIndex);
        reseedIfUntouched();
        holdCurrent();
    }

    // `activeKey` is read asynchronously too (`theme current --json`), and can
    // land either side of the list. Both edges re-seed, so whichever arrives
    // last is the one the selection ends up on.
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
        // Tab is the scope toggle's whenever one is on the surface — taken
        // OFF paging deliberately (VGS-212), and Backtab goes with it: the
        // toggle has two states, so either direction lands on the other one.
        // The arrows, Home/End and the wheel still page.
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
    // Full-bleed: no rounding, no shadow, and no slide offset — a non-zero
    // animation offset pads the layer surface past the screen edge.
    cornerRadius: 0
    enableShadow: false
    // A window border traced around the whole screen is a frame with nothing
    // outside it — the one piece of chrome a full-bleed surface must not draw.
    enableBorder: false
    animationOffset: 0
    // A scrim, not a surface: the desktop stays visible underneath, which is
    // what a wallpaper picker is being judged against. Deliberately not
    // `popupSurfaceColor`, whose alpha is the user's popup-transparency setting
    // and would let an opaque preference hide the very thing being previewed.
    backgroundColor: Theme.withAlpha(Theme.background, 0.5)
    // ONE scrim. VgsModalStandalone paints its own black backdrop behind the
    // content when `modalDarkenBackground` is on, which composited with this
    // surface dimmed the desktop roughly twice as far as the line above says —
    // and by an amount that depended on a user setting. `showBackground` stays
    // true so the backdrop's click-catcher and both smoke paths are unchanged;
    // only its opacity goes.
    backgroundOpacity: 0
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
            readonly property real availableHeight: height - gutter * 2 - captions.height - Theme.spacingL
            // The rail's proportions are Omarchy's, and both dimensions grow
            // together — see SwitcherCarousel.qml. Sized here rather than by
            // filling a box so the captions hug the rail on a tall screen
            // instead of being pushed to the bottom edge.
            // Captions scale with the rail so the name under a 1.6x rail is not
            // set at phone size. Derived from the WIDTH alone, never from
            // `railScale`: the caption block's height is an input to that, and
            // a font size that depended on it would be a binding loop.
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
                // A reopen inside the close animation does not rebuild this tree,
                // so nothing else would re-claim the keys.
                function onOpened() {
                    switcherContent.forceActiveFocus();
                }
            }

            // Clicking away cancels, as it does on every other full-screen
            // surface. The rail's own tiles are above this and consume theirs.
            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }

            // The WHOLE surface scrolls, not just the rail: the pointer is
            // wherever the user left it when the switcher came up, and a picker
            // that only answers the wheel over its tiles reads as broken.
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
                y: (switcherContent.height - height - Theme.spacingL - captions.height) / 2
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

            // Everything that needs words, in one column under the rail: the
            // entry's name, what has been typed, and whichever of "still
            // applying" or the stale-list notice is live.
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
                    // The stale notice only means something over a list there is
                    // something to browse; with none, the empty state already
                    // carries the failure.
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

            // Declared below everything else so it stacks above the
            // click-away MouseArea: the toggle's own clicks must not read
            // as a dismissal.
            Loader {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: carousel.top
                anchors.bottomMargin: Theme.spacingL
                sourceComponent: root.scopeToggle
                // Above the rail it scopes, not the screen edge where it went
                // unseen. NOT Item-scaled: StyledText defaults to
                // NativeRendering, which rasterizes glyphs at their own pixel
                // size and smears under a transform. The pill sizes itself.
            }
        }
    }
}
