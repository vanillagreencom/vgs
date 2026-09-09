import QtQuick
import qs.Common
import qs.Widgets

// Expanded usage meter. The widget host supplies formatting helpers.
Column {
    id: card

    // The AiUsageWidget root. Supplies the shared formatting/colour helpers.
    property var host: null
    // One entry from host.primaryMeters, or from AiUsageFormat.metersFor() for
    // a per-account card.
    property var meter: null
    // False marks stale numbers from an account that failed to report.
    property bool ok: true
    // Caller-supplied detail supports exact spending or helper-provided text.
    property string detailText: ""
    property int labelWeight: Font.Normal

    readonly property int pct: card.meter ? (card.meter.pct || 0) : 0
    readonly property color accent: (card.ok && card.host)
        ? card.host.percentageColor(card.pct) : Theme.error

    Item {
        width: parent.width
        height: Math.max(labelText.implicitHeight, pctText.implicitHeight)

        // Yields to the percentage rather than running under it: a lane named
        // for a model is longer than this row is wide.
        StyledText {
            id: labelText
            anchors.left: parent.left
            anchors.right: pctText.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: card.meter ? card.meter.label : ""
            wrapMode: Text.NoWrap
            maximumLineCount: 1
            elide: Text.ElideRight
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
        // A TRANSLUCENT track, not a container token. The card's hover state
        // is surfaceContainerHighest and so was this, so the empty half of
        // every bar vanished into the card under the pointer — and that
        // token falls back to surfaceContainerHigh on themes that do not
        // define it, which collides at rest too. A wash over whatever is
        // behind it cannot collide with either.
        height: 6
        radius: 3
        color: Theme.withAlpha(Theme.outline, 0.35)

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
