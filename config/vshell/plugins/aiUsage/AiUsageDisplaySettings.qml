import QtQuick
import qs.Common
import qs.Widgets

// How this widget looks: what the bar slots say, and how much of a card is
// open before you click it. Embedded by BOTH settings surfaces — the popout's
// own page and the settings application's — so neither can offer a choice the
// other does not.
//
// A choice between two states where one is plainly the absence of the other is
// a SWITCH, not a pair of buttons: rendering "Show/Hide" and "On/Off" as two
// full-width segments each cost a heading, a caption and a 40px control for
// what a switch says in one row, and five of them ran the page off the screen.
// The two real multi-way choices keep a segmented track, at the small size.
//
// It persists nothing itself. The embedding surface owns the save path,
// because a widget instance and a settings page reach the plugin service by
// different routes, and a component that picked one would only work in one.
Column {
    id: root

    // Current values, as {headlineMode, barValue, barIcons, barColor, cardDetail}.
    property var values: ({})

    signal changed(string key, var value)

    spacing: Theme.spacingS

    readonly property string headlineMode: root.values.headlineMode || "pool"
    readonly property string barValue: root.values.barValue === "left" ? "left" : "used"
    // Absent means on: a fresh install shows the icon and the colour, and a
    // stored false is the only thing that turns either off.
    readonly property bool barIcons: root.values.barIcons !== false
    readonly property bool barColor: root.values.barColor !== false
    readonly property bool expanded: root.values.cardDetail === "expanded"

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

    // The three booleans. Settings rows set horizontalPadding to 0 so their
    // labels line up with the card's own padding and with the choices above.
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        text: "Provider icons"
        description: "Each slot carries its provider's icon, so a number cannot change meaning."
        checked: root.barIcons
        onToggled: on => root.changed("barIcons", on)
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        text: "Colour by usage"
        description: "Numbers turn amber and red as a limit fills."
        checked: root.barColor
        onToggled: on => root.changed("barColor", on)
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        text: "Expand cards"
        description: "Every limit gets its own bar and reset countdown, without clicking a card."
        checked: root.expanded
        onToggled: on => root.changed("cardDetail", on ? "expanded" : "compact")
    }
}
