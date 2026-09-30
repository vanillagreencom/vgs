import QtQuick
import qs.Commons
import qs.Ui

// A rail of angled cards over a model: the current card expanded in the
// middle, the others as slices beside it that overlap their neighbours.
// Every length is a `carousel` token times one unit: the carousel's width
// over the reference rail or its height over the expanded card's, the
// smaller, held between `carousel.minScale` and `carousel.maxScale`. The
// rail is centred in the carousel, and a side shows the slices that fit
// whole beside the expanded card. `implicitHeight` is the expanded card's
// height at the width's unit alone, so a container that fits its content
// gives the rail the height its width asks for.
//
// `model` is anything a Repeater takes. `delegate` is the content of one
// card, built with the card's area as its parent; its root declares
// `required property var modelData`, the card's entry, and `required
// property size decodeSize`, what an image in it decodes at, in device
// pixels: the drawn size for the current card and its two neighbours, so a
// step finds the next image decoded, the longer side no more than
// `carousel.decodeCap`; the slice size for every other card. When the
// delegate root declares a `current` property, the carousel binds it to
// whether that card is selected. A built slot can survive a model change
// at the same index, so the carousel also rebinds modelData after creation.
// Only the cards within `carousel.band` slices
// of the shown ones are built; the rest hold no content.
//
// A click on a slice makes it current and a click on the current card
// emits `activated`; a click lands on the card whose parallelogram holds
// it, the nearer to the current card where two meet, and the card under
// the pointer by the same rule is its AngledCard's `hovered`. Left, Shift+Tab and a
// wheel notch up step back, Right, Tab and a notch down step forward, each
// wrapping at the ends, and Home and End go to the first and the last
// card. A wheel notch is 120 units of Qt's angleDelta, eighths of a degree
// at 15 degrees a notch, and parts of a notch add up.
//
// The rail shows one event-loop turn after the carousel is visible with a
// size, so its first frame is the settled layout. From then on a new
// `currentIndex` within the shown slices of the index the rail is drawn at
// glides there over `carousel.duration`; a farther one, a wrap or Home and
// End across the model included, lands at once, as every move does before
// the rail settles and while the duration is 0, as under `motion.scale` 0.
// A card is shown while within the shown slices of the drawn index or of
// `currentIndex`, and built while within the band of either, so a glide
// keeps the cards it leaves and builds the ones it reaches; the rail clips
// to the carousel, so a card on its way in or out draws inside it.
Item {
    id: root

    property var model: 0
    property Component delegate: null
    property int currentIndex: 0
    // Whether Tab and Shift+Tab step cards. Full-screen browsers turn this
    // off so Tab switches their top-level tabs.
    property bool tabSteps: true
    // Device pixels per pixel of the carousel, for the decode sizes.
    property real devicePixelRatio: Screen.devicePixelRatio

    signal activated(int index)

    implicitHeight: Theme.carousel.expandedHeight * internal.widthUnit

    onCurrentIndexChanged: internal.follow()

    // Move `delta` cards from the current one, wrapping at either end.
    function step(delta) {
        const count = cards.count;
        if (count > 0)
            currentIndex = ((currentIndex + delta) % count + count) % count;
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            step(-1);
            break;
        case Qt.Key_Backtab:
            if (!tabSteps) return;
            step(-1);
            break;
        case Qt.Key_Right:
            step(1);
            break;
        case Qt.Key_Tab:
            if (!tabSteps) return;
            step(event.modifiers & Qt.ShiftModifier ? -1 : 1);
            break;
        case Qt.Key_Home:
            step(-currentIndex);
            break;
        case Qt.Key_End:
            step(cards.count - 1 - currentIndex);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    QtObject {
        id: internal

        readonly property var tokens: Theme.carousel

        // The rail's geometry, computed once for every card.
        readonly property real reference: tokens.expandedWidth + tokens.referenceSteps * (tokens.sliceWidth - tokens.overlap) + 2 * tokens.referenceMargin
        readonly property real unit: Math.max(tokens.minScale, Math.min(tokens.maxScale, root.width / reference, root.height / tokens.expandedHeight))
        readonly property real widthUnit: Math.min(Math.max(root.width / reference, tokens.minScale), tokens.maxScale)
        readonly property real expandedWidth: tokens.expandedWidth * unit
        readonly property real expandedHeight: tokens.expandedHeight * unit
        readonly property real sliceWidth: tokens.sliceWidth * unit
        readonly property real sliceHeight: tokens.sliceHeight * unit
        readonly property real overlap: tokens.overlap * unit
        // A theme whose overlap reaches the slice width stacks the slices
        // one pixel apart.
        readonly property real pitch: Math.max(sliceWidth - overlap, 1)
        readonly property real left: (root.width - expandedWidth) / 2
        readonly property real top: (root.height - expandedHeight) / 2
        readonly property real sliceTop: top + (expandedHeight - sliceHeight) / 2
        readonly property int slicesPerSide: Math.max(0, Math.floor(left / pitch))
        readonly property real reach: slicesPerSide + tokens.band
        readonly property real skew: Theme.angledCard.skew * unit
        readonly property size sliceDecode: Qt.size(Math.round(sliceWidth * root.devicePixelRatio), Math.round(sliceHeight * root.devicePixelRatio))
        readonly property real fullScale: root.devicePixelRatio * Math.min(1, tokens.decodeCap / (Math.max(expandedWidth, expandedHeight) * root.devicePixelRatio))
        readonly property size fullDecode: Qt.size(Math.round(expandedWidth * fullScale), Math.round(expandedHeight * fullScale))

        // The index the rail is drawn at. Only follow() moves it, once per
        // change of `currentIndex`, a declared one included: a glide to a
        // target within the shown slices, otherwise straight there. A glide
        // of duration 0 lands at once, so motion.scale 0 needs no branch.
        property real position: 0
        function follow() {
            const target = root.currentIndex;
            glide.stop();
            const glides = settled && Math.abs(target - position) <= slicesPerSide;
            if (glides) {
                glide.from = position;
                glide.to = target;
                glide.start();
            } else {
                position = target;
            }
        }

        readonly property bool ready: root.visible && root.width > 0 && root.height > 0
        property bool settled: false
        onReadyChanged: {
            settled = false;
            wheel = 0;
            if (ready) Qt.callLater(internal.settle);
        }
        Component.onCompleted: if (ready) Qt.callLater(internal.settle)
        function settle() { settled = ready; }

        // Wheel travel short of a notch, kept for the next event.
        property real wheel: 0
        readonly property int notch: 120

        // The card `offset` places from the current one. A fractional
        // offset lies on the line between the two whole places around it,
        // so every card moves with the rail.
        function place(offset) {
            const whole = Math.floor(offset);
            const a = at(whole);
            const b = at(whole + 1);
            const t = offset - whole;
            return Qt.rect(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.width + (b.width - a.width) * t, a.height + (b.height - a.height) * t);
        }
        function at(offset) {
            if (offset === 0) return Qt.rect(left, top, expandedWidth, expandedHeight);
            if (offset < 0) return Qt.rect(left + offset * pitch, sliceTop, sliceWidth, sliceHeight);
            return Qt.rect(left + expandedWidth - overlap + (offset - 1) * pitch, sliceTop, sliceWidth, sliceHeight);
        }

        // Whether `point`, in the card's coordinates, lies inside its
        // parallelogram.
        function inside(card, point) {
            const c = card.corners;
            const t = point.y / card.height;
            return t >= 0 && t <= 1 && point.x >= c[0].x + (c[3].x - c[0].x) * t && point.x <= c[1].x + (c[2].x - c[1].x) * t;
        }
    }

    NumberAnimation {
        id: glide
        target: internal
        property: "position"
        duration: Theme.carousel.duration
        easing.type: Theme.motion.easing.standard
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: wheel => {
            internal.wheel += wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x;
            const notches = Math.trunc(internal.wheel / internal.notch);
            internal.wheel -= notches * internal.notch;
            root.step(-notches);
        }
    }

    Item {
        id: rail
        anchors.fill: parent
        visible: internal.settled
        clip: true

        Repeater {
            id: cards
            model: root.model

            Item {
                id: slot

                required property int index
                required property var modelData
                readonly property int offset: index - root.currentIndex
                // The card's distance from the target or from the drawn
                // index, whichever is nearer. A glide never starts farther
                // than the shown slices from its target, so a card farther
                // than the band and the shown slices from the target is as
                // far from the drawn index too, and reads the target alone:
                // only the cards near the rail follow a glide frame by frame.
                readonly property real distance: Math.abs(offset) > internal.reach + internal.slicesPerSide ? Math.abs(offset) : Math.min(Math.abs(offset), Math.abs(index - internal.position))
                // Within n cards means short of card n + 1, so a card between
                // two whole places stays while any of it can be in the rail.
                readonly property bool shown: distance < internal.slicesPerSide + 1
                readonly property bool retained: distance < internal.reach + 1
                readonly property size decodeSize: Math.abs(offset) <= 1 ? internal.fullDecode : internal.sliceDecode
                // Only a built card follows the rail, so a step places the
                // band and not the whole model.
                readonly property rect place: retained ? internal.place(index - internal.position) : Qt.rect(0, 0, 0, 0)

                x: place.x
                y: place.y
                width: place.width
                height: place.height
                z: -Math.abs(offset)
                visible: shown

                Loader {
                    anchors.fill: parent
                    active: slot.retained
                    sourceComponent: Component {
                        Item {
                            AngledCard {
                                id: card
                                anchors.fill: parent
                                skew: internal.skew
                                selected: slot.offset === 0
                                hovered: pointer.containsMouse

                                Item {
                                    id: holder
                                    anchors.fill: parent
                                    // A Loader sets no required property of the item it
                                    // loads, so the content is built here with its two.
                                    // A delegate that declares another required property
                                    // builds nothing, and one without decodeSize could not
                                    // follow the card; either leaves the card empty.
                                    Component.onCompleted: {
                                        if (root.delegate === null) return;
                                        const content = root.delegate.createObject(holder, { modelData: slot.modelData, decodeSize: slot.decodeSize });
                                        const built = content !== null && "decodeSize" in content;
                                        if (!built) {
                                            if (content !== null) content.destroy();
                                            console.warn("CardCarousel: no content index=" + slot.index + "; the delegate's root must build with required modelData and decodeSize");
                                            return;
                                        }
                                        content.decodeSize = Qt.binding(() => slot.decodeSize);
                                        content.modelData = Qt.binding(() => slot.modelData);
                                        if ("current" in content)
                                            content.current = Qt.binding(() => slot.offset === 0);
                                    }
                                }
                            }
                            MouseArea {
                                id: pointer
                                anchors.fill: parent
                                hoverEnabled: true
                                PointerCursor {}
                                containmentMask: QtObject {
                                    function contains(point: point): bool { return internal.inside(card, point); }
                                }
                                onClicked: {
                                    if (slot.offset === 0) root.activated(slot.index);
                                    else root.currentIndex = slot.index;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
