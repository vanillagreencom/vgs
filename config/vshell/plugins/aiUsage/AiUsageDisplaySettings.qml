import QtQuick
import qs.Common
import qs.Widgets

// How this widget looks: what the bar slots say, which providers take one and
// in what order, and how much of a card is open before you click it. Embedded
// by BOTH settings surfaces — the popout's own page and the settings
// application's — so neither can offer a choice the other does not.
//
// A choice between two states where one is plainly the absence of the other is
// a SWITCH, not a pair of buttons: rendering "Show/Hide" and "On/Off" as two
// full-width segments each cost a heading and a 40px control for what a switch
// says in one row, and five of them ran the page off the screen. The real
// multi-way choices keep a segmented track, at the small size.
//
// No row carries explanatory prose. Every control here is named by what it
// does, and a caption under each one doubled the height of the page to repeat
// its own label back.
//
// It persists nothing itself. The embedding surface owns the save path,
// because a widget instance and a settings page reach the plugin service by
// different routes, and a component that picked one would only work in one.
Column {
    id: root

    // Current values, as {headlineMode, barValue, barIconMode, barColor,
    // hideUnusedLanes, cardDetail, providerFilter}.
    property var values: ({})

    signal changed(string key, var value)

    // Declared here rather than left to the embedding surface: the settings
    // application supplies one through PluginSettings, the popout does not, and
    // a page that rendered in two typographies depending on where it was shown
    // is the thing this page exists to prevent.
    readonly property bool settingsSurface: true

    spacing: Theme.spacingS

    // Its own catalog rather than the widget's. This page is embedded by the
    // settings application too, which is not a widget and has no catalog to
    // lend it; a `logic:` property would bind to itself in the surface that
    // does have one.
    AiUsageLogic {
        id: catalog
    }

    // AiUsageFilterRow reaches a provider's mark through its host. Here that is
    // this page, which forwards the two calls the mark needs.
    function providerAsset(p) {
        return catalog.providerAsset(p);
    }
    function providerIcon(p) {
        return catalog.providerIcon(p);
    }

    readonly property string headlineMode: root.values.headlineMode || "pool"
    readonly property string barValue: root.values.barValue === "left" ? "left" : "used"
    readonly property string barIconMode: catalog.barIconMode(root.values.barIconMode, root.values.barIcons)
    // Absent means on: a fresh install shows the colour and leaves untouched
    // limits off compact cards, and a stored false is the only thing that
    // turns either off.
    readonly property bool barColor: root.values.barColor !== false
    readonly property bool hideUnused: root.values.hideUnusedLanes !== false
    readonly property bool expanded: root.values.cardDetail === "expanded"
    readonly property var providerFilter: root.values.providerFilter || []

    // One multi-way choice: its name on the left, its current value in a
    // dropdown on the right. The same shape both Mercury settings surfaces use,
    // and VgsDropdown is what SelectionSetting and MercuryOptionRow each end at,
    // so a choice reads the same wherever the shell asks for one.
    //
    // It replaced a segmented track, which charged the full width of the page
    // for three words and grew a segment narrower with every option added — the
    // three tracks together were taller than everything else on this page.
    //
    // VgsDropdown speaks in LABELS: the list it shows and the value it reports
    // back are both label strings. Everything that stores a setting here speaks
    // in keys. The two lists are parallel by construction, and this component
    // owns that translation so neither the rows above nor the catalog below has
    // to carry it.
    component Choice: Item {
        id: choice

        property string title: ""
        property var keys: []
        property var labels: []
        property string current: ""

        signal picked(string key)

        width: parent ? parent.width : 0
        implicitHeight: dropdown.implicitHeight
        height: implicitHeight

        readonly property string currentLabel: {
            const at = choice.keys.indexOf(choice.current);
            return at >= 0 && at < choice.labels.length ? String(choice.labels[at]) : "";
        }

        VgsDropdown {
            id: dropdown

            width: parent.width
            text: choice.title
            options: choice.labels
            currentValue: choice.currentLabel
            dropdownWidth: 170

            onValueChanged: newValue => {
                const at = choice.labels.indexOf(String(newValue));
                // Report the KEY, and only for a real change: the dropdown
                // announces a pick whether or not it moved, and a settings write
                // per open would stamp the store for nothing.
                if (at >= 0 && at < choice.keys.length && choice.keys[at] !== choice.current)
                    choice.picked(String(choice.keys[at]));
            }
        }
    }

    Choice {
        title: "Bar number"
        keys: ["pool", "best", "worst"]
        labels: ["Average", "Most left", "Most used"]
        current: root.headlineMode
        onPicked: key => root.changed("headlineMode", key)
    }

    Choice {
        title: "Bar shows"
        keys: ["used", "left"]
        labels: ["Used", "Left"]
        current: root.barValue
        onPicked: key => root.changed("barValue", key)
    }

    // The keys come from the catalog, so a mode added there reaches both
    // settings surfaces without either one listing modes of its own.
    Choice {
        title: "Bar icons"
        keys: catalog.iconModes()
        labels: ["None", "One", "Per slot"]
        current: root.barIconMode
        onPicked: key => root.changed("barIconMode", key)
    }

    // Settings rows set horizontalPadding to 0 so their labels line up with the
    // card's own padding and with the choices above, and drop the row-wide
    // hover wash with it: a full-bleed wash behind an unpadded label reads as a
    // box drawn around the text, and the switch already says the row is live.
    // Press feedback and the click stay.
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: "Colour by usage"
        checked: root.barColor
        onToggled: on => root.changed("barColor", on)
    }

    // Which providers take a slot, and in what order. The bar and the popout
    // both walk this one list, so a slot and its section can never disagree
    // about where a provider sits.
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        topPadding: Theme.spacingXS

        StyledText {
            text: "Bar slots"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightSectionHeader
            color: Theme.surfaceText
        }

        // Rows are POSITIONED, not laid out by a Column, because a drag has to
        // move them: a Column owns its children's y and would fight the working
        // order for it.
        Item {
            id: slots

            width: parent.width
            height: slots.committed.length * slots.pitch

            readonly property var committed: catalog.filterOrder(root.providerFilter)
            readonly property int selectedCount: catalog.selectedProviders(root.providerFilter).length
            readonly property int rowHeight: 32
            readonly property int pitch: slots.rowHeight + Theme.spacingXS

            // The arrangement under the cursor, and the row holding the grab.
            // The Repeater's model stays `committed` for the whole drag: the
            // model is derived from the stored setting, so writing on every
            // crossing would rebuild every delegate — including the one holding
            // the mouse grab — and the drag would end after its first step.
            property var working: []
            property string dragging: ""

            function slotY(provider) {
                const order = slots.dragging === "" ? slots.committed : slots.working;
                const at = order.indexOf(provider);
                return (at < 0 ? 0 : at) * slots.pitch;
            }

            function beginDrag(provider) {
                slots.working = slots.committed.slice();
                slots.dragging = provider;
            }

            // Land on the slot the pointer is over, clamped to the SELECTED
            // range: the unselected providers sit in a tail that takes no bar
            // slot, so a position among them is not a position.
            function dragTo(provider, listY) {
                if (slots.dragging !== provider)
                    return;
                const limit = Math.max(0, slots.selectedCount - 1);
                const want = Math.max(0, Math.min(limit, Math.floor(listY / slots.pitch)));
                const next = slots.working.slice();
                const at = next.indexOf(provider);
                if (at < 0 || at === want)
                    return;
                next.splice(at, 1);
                next.splice(want, 0, provider);
                slots.working = next;
            }

            function endDrag(provider) {
                if (slots.dragging !== provider)
                    return;
                const settled = slots.working.slice();
                slots.dragging = "";
                root.changed("providerFilter", catalog.canonicalFilter(settled));
            }

            Repeater {
                model: slots.committed

                AiUsageFilterRow {
                    id: slotRow

                    required property string modelData

                    width: slots.width
                    height: slots.rowHeight
                    y: slots.slotY(modelData)
                    // The row being dragged draws over the ones moving past it.
                    z: slots.dragging === modelData ? 1 : 0

                    host: root
                    provider: modelData
                    label: catalog.providerName(modelData)
                    checked: catalog.filterHas(root.providerFilter, modelData)
                    showMove: true
                    canMoveUp: catalog.canMoveProvider(root.providerFilter, modelData, -1)
                    canMoveDown: catalog.canMoveProvider(root.providerFilter, modelData, 1)
                    // Only a provider that HAS a slot can be dragged to another
                    // one, which is the same rule the arrows follow.
                    showDrag: catalog.filterHas(root.providerFilter, modelData)
                    // Setup belongs to the popout's filter, which is a step away
                    // from the accounts it configures. This page is already inside
                    // settings and has the provider sections under it.
                    showSetup: false

                    // The row under the hand snaps; the ones it displaces slide,
                    // so the list reads as one arrangement rather than as rows
                    // appearing in new places.
                    Behavior on y {
                        enabled: slots.dragging !== slotRow.modelData
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Easing.OutCubic
                        }
                    }

                    onToggled: root.changed("providerFilter",
                                            catalog.toggleFilter(root.providerFilter, modelData))
                    onMoveUp: root.changed("providerFilter",
                                           catalog.moveProvider(root.providerFilter, modelData, -1))
                    onMoveDown: root.changed("providerFilter",
                                             catalog.moveProvider(root.providerFilter, modelData, 1))
                    onDragStarted: slots.beginDrag(modelData)
                    onDragMoved: listY => slots.dragTo(modelData, listY)
                    onDragEnded: slots.endDrag(modelData)
                }
            }
        }
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: "Expand cards"
        checked: root.expanded
        onToggled: on => root.changed("cardDetail", on ? "expanded" : "compact")
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: "Hide unused limits"
        checked: root.hideUnused
        onToggled: on => root.changed("hideUnusedLanes", on)
    }
}
