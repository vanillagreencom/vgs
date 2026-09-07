import QtQuick
import qs.Common
import qs.Widgets

// How this widget looks: what the bar slots say, and how much of a card is
// open before you click it. Embedded by BOTH settings surfaces — the popout's
// own page and the settings application's — so neither can offer a choice the
// other does not.
//
// It persists nothing itself. The embedding surface owns the save path,
// because a widget instance and a settings page reach the plugin service by
// different routes, and a component that picked one would only work in one.
Column {
    id: root

    // Current values, as {headlineMode, barValue, barIcons, barColor, cardDetail}.
    property var values: ({})

    signal changed(string key, var value)

    spacing: Theme.spacingM

    readonly property string headlineMode: root.values.headlineMode || "pool"
    readonly property string barValue: root.values.barValue === "left" ? "left" : "used"
    // Absent means on: a fresh install shows the icon and the colour, and a
    // stored false is the only thing that turns either off.
    readonly property bool barIcons: root.values.barIcons !== false
    readonly property bool barColor: root.values.barColor !== false
    readonly property string cardDetail: root.values.cardDetail === "expanded" ? "expanded" : "compact"

    // One choice: a caption that changes with it, then its options in a row.
    component ChoiceRow: Column {
        id: choice

        property string title: ""
        property string caption: ""
        property var options: []
        property string current: ""

        signal picked(string key)

        width: parent ? parent.width : 0
        spacing: Theme.spacingXS

        StyledText {
            text: choice.title
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: choice.caption
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Row {
            id: optionRow
            width: parent.width
            spacing: Theme.spacingXS

            Repeater {
                model: choice.options

                VgsButton {
                    required property var modelData

                    readonly property bool selected: choice.current === modelData.key
                    text: modelData.label
                    width: (optionRow.width - Theme.spacingXS * (choice.options.length - 1))
                        / Math.max(1, choice.options.length)
                    backgroundColor: selected ? Theme.primary : Theme.surfaceContainerHighest
                    textColor: selected ? Theme.primaryText : Theme.surfaceText
                    onClicked: choice.picked(modelData.key)
                }
            }
        }
    }

    ChoiceRow {
        title: "Bar number"
        caption: root.headlineMode === "best"
            ? "The account with the most headroom left."
            : (root.headlineMode === "worst"
               ? "The most exhausted account."
               : "Average across accounts, each counted at its tightest limit.")
        options: [
            { key: "pool", label: "Average" },
            { key: "best", label: "Most left" },
            { key: "worst", label: "Most used" }
        ]
        current: root.headlineMode
        onPicked: key => root.changed("headlineMode", key)
    }

    ChoiceRow {
        title: "Bar shows"
        caption: root.barValue === "left"
            ? "How much of the limit is still available."
            : "How much of the limit has been consumed."
        options: [
            { key: "used", label: "Used" },
            { key: "left", label: "Left" }
        ]
        current: root.barValue
        onPicked: key => root.changed("barValue", key)
    }

    ChoiceRow {
        title: "Provider icons"
        caption: root.barIcons
            ? "Each slot carries its provider's icon, so a number cannot change meaning."
            : "Numbers only. Slots keep their order, which is the only thing naming them."
        options: [
            { key: "on", label: "Show" },
            { key: "off", label: "Hide" }
        ]
        current: root.barIcons ? "on" : "off"
        onPicked: key => root.changed("barIcons", key === "on")
    }

    ChoiceRow {
        title: "Colour by usage"
        caption: root.barColor
            ? "Numbers turn amber and red as a limit fills."
            : "One colour, whatever the number says."
        options: [
            { key: "on", label: "On" },
            { key: "off", label: "Off" }
        ]
        current: root.barColor ? "on" : "off"
        onPicked: key => root.changed("barColor", key === "on")
    }

    ChoiceRow {
        title: "Cards"
        caption: root.cardDetail === "expanded"
            ? "Every limit gets its own bar and reset countdown."
            : "One row per limit. Click a card for its full detail."
        options: [
            { key: "compact", label: "Compact" },
            { key: "expanded", label: "Expanded" }
        ]
        current: root.cardDetail
        onPicked: key => root.changed("cardDetail", key)
    }
}
