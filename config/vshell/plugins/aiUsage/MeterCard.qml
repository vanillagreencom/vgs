import QtQuick
import qs.Common
import qs.Widgets

// One usage meter in full-card form: label, percentage, bar, detail line.
//
// The single-account view and the expanded per-account card rendered identical
// markup from two separate copies, so every per-meter field had to be written
// twice here and a third time in MeterRow. Now it is written once. (VGS-72)
//
// `host` is the widget root rather than one function property per helper:
// the delegate needs percentageColor, resetLabel and the spend formatters, and
// threading four callables through every call site is the duplication this is
// meant to remove. A sibling type resolves from the plugin's own directory with
// no import — verified in the running shell, see the commit message.
Column {
    id: card

    // The AiUsageWidget root. Supplies the shared formatting/colour helpers.
    property var host: null
    // One entry from host.metersFor()/host.primaryMeters.
    property var meter: null
    // False when the account this meter belongs to failed to report: the
    // numbers are stale, so they read as error rather than as a healthy
    // percentage. The single-account view only renders when the fetch
    // succeeded, so it leaves this at true.
    property bool ok: true
    // The two call sites word this line differently — the single-account card
    // spells out the exact spend, the expanded card prefers the engine's own
    // detail string. Everything above it is identical, which is the point.
    property string detailText: ""
    property int labelWeight: Font.Normal

    readonly property int pct: card.meter ? (card.meter.pct || 0) : 0
    readonly property color accent: (card.ok && card.host)
        ? card.host.percentageColor(card.pct) : Theme.error

    Item {
        width: parent.width
        height: Math.max(labelText.implicitHeight, pctText.implicitHeight)

        StyledText {
            id: labelText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: card.meter ? card.meter.label : ""
            font.pixelSize: Theme.fontSizeMedium
            font.weight: card.labelWeight
            color: Theme.surfaceText
        }

        StyledText {
            id: pctText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: card.pct + "%"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Bold
            color: card.accent
        }
    }

    Rectangle {
        width: parent.width
        height: 6
        radius: 3
        color: Theme.surfaceContainerHighest

        Rectangle {
            width: parent.width * Math.max(0, Math.min(card.pct, 100)) / 100
            height: parent.height
            radius: 3
            color: card.accent
        }
    }

    StyledText {
        text: card.detailText
        visible: text.length > 0
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }
}
