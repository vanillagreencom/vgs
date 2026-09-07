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
// full-width segments each cost a heading, a caption and a 40px control for
// what a switch says in one row, and five of them ran the page off the screen.
// The real multi-way choices keep a segmented track, at the small size.
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

    // One multi-way choice: a label, the track, and a caption that follows the
    // selection so the page says what the current setting means rather than
    // what all of them mean.
    component Choice: Column {
        id: choice

        property string title: ""
        property string caption: ""
        property var keys: []
        property var labels: []
        property string current: ""

        signal picked(string key)

        width: parent ? parent.width : 0
        spacing: Theme.spacingXS
        topPadding: Theme.spacingXS

        StyledText {
            text: choice.title
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        VgsButtonGroup {
            width: parent.width
            model: choice.labels
            currentIndex: choice.keys.indexOf(choice.current)
            selectionMode: "single"
            size: "small"
            fillWidth: true
            onSelectionChanged: (index, selected) => {
                if (selected)
                    choice.picked(choice.keys[index]);
            }
        }

        StyledText {
            width: parent.width
            text: choice.caption
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    Choice {
        title: "Bar number"
        caption: root.headlineMode === "best"
            ? "The account with the most headroom left."
            : (root.headlineMode === "worst"
               ? "The most exhausted account."
               : "Average across accounts, each counted at its tightest limit.")
        keys: ["pool", "best", "worst"]
        labels: ["Average", "Most left", "Most used"]
        current: root.headlineMode
        onPicked: key => root.changed("headlineMode", key)
    }

    Choice {
        title: "Bar shows"
        caption: root.barValue === "left"
            ? "How much of each limit is still available."
            : "How much of each limit has been consumed."
        keys: ["used", "left"]
        labels: ["Used", "Left"]
        current: root.barValue
        onPicked: key => root.changed("barValue", key)
    }

    // The keys come from the catalog, so a mode added there reaches both
    // settings surfaces without either one listing modes of its own.
    Choice {
        title: "Bar icons"
        caption: root.barIconMode === "none"
            ? "Numbers only."
            : (root.barIconMode === "one"
               ? "One icon for the whole widget, ahead of every number."
               : "Each slot carries its provider's mark, so a number cannot change meaning.")
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
        description: "Numbers turn amber and red as a limit fills."
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
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        Repeater {
            model: catalog.filterOrder(root.providerFilter)

            AiUsageFilterRow {
                required property string modelData

                host: root
                provider: modelData
                label: catalog.providerName(modelData)
                checked: catalog.filterHas(root.providerFilter, modelData)
                showMove: true
                canMoveUp: catalog.canMoveProvider(root.providerFilter, modelData, -1)
                canMoveDown: catalog.canMoveProvider(root.providerFilter, modelData, 1)
                // Setup belongs to the popout's filter, which is a step away
                // from the accounts it configures. This page is already inside
                // settings and has the provider sections under it.
                showSetup: false
                onToggled: root.changed("providerFilter",
                                        catalog.toggleFilter(root.providerFilter, modelData))
                onMoveUp: root.changed("providerFilter",
                                       catalog.moveProvider(root.providerFilter, modelData, -1))
                onMoveDown: root.changed("providerFilter",
                                         catalog.moveProvider(root.providerFilter, modelData, 1))
            }
        }

        StyledText {
            width: parent.width
            text: "A provider that is off takes no bar slot and no popout section. " +
                  "Turning the last one off brings them all back."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: "Expand cards"
        description: "Every limit gets its own bar and reset countdown, without clicking a card."
        checked: root.expanded
        onToggled: on => root.changed("cardDetail", on ? "expanded" : "compact")
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: "Hide unused limits"
        description: "A per-model limit you have never used is left off compact cards. Expanding a card still lists every one."
        checked: root.hideUnused
        onToggled: on => root.changed("hideUnusedLanes", on)
    }
}
