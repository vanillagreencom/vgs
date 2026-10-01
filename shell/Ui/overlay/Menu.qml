import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui

// A menu of MenuItem entries under the item it is declared in, in its own
// surface. One ListCursor draws the highlight and travels between entries.
// Up and Down move the highlight, a hover moves it once the pointer moves
// (ListCursor), Enter triggers the highlighted entry, a click triggers an
// entry, and any trigger closes the menu; a
// press outside and Escape close it too. Typing letters highlights the
// first reachable entry whose text starts with them, the letters kept for
// `menu.typeahead` milliseconds. Entries taller than `maxHeight` scroll
// inside the menu, and the highlighted entry is kept in view; opening
// shows the top and highlights the first checked entry, in view. It follows its anchor when that
// moves and closes when it hides. The declaring item is an invisible,
// sizeless member of its parent. The entries fill the list inside the
// menu's border, so an entry's highlight meets the border at the top and
// both sides (Theme.menuListInset); each entry insets its own text, and
// keeps `scrollArea.gutter` clear at its end for the bar while the entries
// overflow. Under a rounded corner the list is cut to the window's rounded
// interior (ListMask), so an entry scrolled part way past an edge stays
// inside the curve.
Item {
    id: root

    default property alias entries: column.data
    readonly property bool opened: window.visible
    readonly property Item anchorItem: parent
    property int currentIndex: -1
    // The height the entries take before the menu scrolls.
    property real maxHeight: Theme.menu.maxHeight
    readonly property string typed: nav.typed
    readonly property alias scrollArea: scroll
    // The list's top and bottom inset inside the window; its side inset is
    // the border.
    readonly property real listInset: Theme.menuListInset(window.width)

    visible: false

    property bool counted: false
    function share(open) {
        if (open === counted) return;
        counted = open;
        if (open) OverlayState.opened(); else OverlayState.closed();
    }
    Component.onDestruction: share(false)

    // The MenuItem children of the column, in order, and the ones the
    // keyboard may reach: enabled and shown.
    function items() { return column.children.filter(child => child.triggered !== undefined); }
    function reachable(item) { return item.enabled && item.visible; }

    function open() {
        nav.typed = "";
        // The cursor lands on the opening entry rather than travelling
        // from where the last opening left it.
        plate.disarm();
        plate.snap();
        currentIndex = items().findIndex(item => reachable(item) && item.checked);
        if (currentIndex === -1) nav.first();
        window.visible = true;
        scope.forceActiveFocus();
        scroll.contentY = 0;
        reveal();
    }
    function close() { window.visible = false; }
    function toggle() { if (opened) close(); else open(); }

    // Move the highlight by `step` over the reachable entries: from none,
    // Down takes the first and Up the last.
    function move(step) {
        nav.moveBy(step);
    }

    // Highlight the entry at `index` from a key: the pointer resting over
    // the menu takes the highlight again only once it moves.
    function keyTo(index) { plate.disarm(); currentIndex = index; }

    function triggerCurrent() {
        const all = items();
        if (currentIndex >= 0 && currentIndex < all.length && reachable(all[currentIndex])) all[currentIndex].triggered();
    }

    // Add `letter` to the typed letters and highlight the first reachable
    // entry whose text starts with them; when none does, start again from
    // `letter` alone. Answers whether an entry matched.
    function typeAhead(letter) {
        return nav.typeAhead(letter);
    }

    // Scroll the highlighted entry into view.
    function reveal() {
        const all = items();
        if (currentIndex < 0 || currentIndex >= all.length) return;
        nav.reveal(currentIndex);
    }

    // The widest entry by its own content, before the column sets every
    // entry's width.
    readonly property real widest: {
        let width = 0;
        for (const item of items()) width = Math.max(width, item.implicitWidth);
        return width;
    }

    onCurrentIndexChanged: {
        items().forEach((item, index) => { item.highlighted = index === currentIndex; });
        reveal();
    }

    property KeyNav nav: KeyNav {
        count: root.items().length
        currentIndex: root.currentIndex
        viewHeight: scroll.height
        rowHeight: Theme.menu.item.height
        reachable: index => root.reachable(root.items()[index])
        labelAt: index => root.items()[index].text
        cursor: plate
        flickable: scroll
        itemAt: index => root.items()[index]
        onMoved: index => root.keyTo(index)
        onActivated: index => root.triggerCurrent()
    }

    // Every entry draws its highlight through the menu's cursor, and a
    // hover the cursor lets through highlights a reachable entry.
    readonly property Instantiator pointers: Instantiator {
        model: root.items()
        delegate: Connections {
            required property var modelData
            target: modelData
            Component.onCompleted: {
                modelData.cursor = plate;
                modelData.barRoom = Qt.binding(() => scroll.overflowing ? Theme.scrollArea.gutter : 0);
            }
            function onPointed() { if (root.reachable(modelData)) root.currentIndex = root.items().indexOf(modelData); }
        }
    }

    // Every entry's trigger closes the menu, by click or by key.
    readonly property Instantiator closers: Instantiator {
        model: root.opened ? root.items() : []
        delegate: Connections {
            required property var modelData
            target: modelData
            function onTriggered() { root.close(); }
        }
    }

    PopupWindow {
        id: window

        anchor.item: root.anchorItem
        anchor.edges: Edges.Bottom | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
        anchor.margins.bottom: -Theme.menu.gap
        grabFocus: true
        visible: false
        color: "transparent"
        // As wide as the widest entry, rounded up to the whole pixel the
        // window takes, never wider than `menu.maxWidth` or the output
        // allows; a longer entry elides.
        implicitWidth: Math.min(OverlayState.widthFor(root.anchorItem, Theme.menu.maxWidth), Math.max(Theme.menu.minWidth, Math.ceil(root.widest) + 2 * Theme.border.thin))
        implicitHeight: Math.max(1, Math.min(column.implicitHeight, root.maxHeight) + 2 * root.listInset)
        onVisibleChanged: root.share(visible)

        FocusScope {
            id: scope
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()
            Keys.onTabPressed: event => event.accepted = true
            Keys.onBacktabPressed: event => event.accepted = true
            Keys.onPressed: event => {
                event.accepted = nav.handle(event);
            }

            Rectangle {
                anchors.fill: parent
                radius: Theme.menu.radius
                color: Theme.menu.background
                border.width: Theme.border.thin
                border.color: Theme.menu.border
            }

            // The entries span the list inside the border; the bar draws
            // over the strip each entry keeps clear at its end. Under a
            // rounded corner the list is cut to the curve of the interior.
            ScrollArea {
                id: scroll
                x: Theme.border.thin
                y: root.listInset
                width: parent.width - 2 * Theme.border.thin
                height: parent.height - 2 * root.listInset
                barOverContent: true
                layer.enabled: listMask.cuts
                layer.smooth: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: listMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1
                }

                ListCursor {
                    id: plate
                    color: Theme.menu.item.hover
                    pressedColor: Theme.menu.item.pressed
                    radius: Theme.menu.item.radius
                }

                Column {
                    id: column
                    width: scroll.contentWidth
                }
            }

            ListMask {
                id: listMask
                anchors.fill: scroll
                frameWidth: window.width
                frameHeight: window.height
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
