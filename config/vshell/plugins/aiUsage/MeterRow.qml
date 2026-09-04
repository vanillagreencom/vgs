import QtQuick
import qs.Common
import qs.Widgets

// Compact usage meter for collapsed account summaries. MeterCard is the
// expanded form. Column sizing includes added detail rows automatically.
Column {
    id: row

    // The AiUsageWidget root. Supplies the shared formatting/colour helpers.
    property var host: null
    property var meter: null
    // False when the owning account failed to report — see MeterCard.
    property bool ok: true

    readonly property int pct: row.meter ? (row.meter.pct || 0) : 0
    readonly property color accent: (row.ok && row.host)
        ? row.host.percentageColor(row.pct) : Theme.error

    bottomPadding: 5
    spacing: 2

    Item {
        width: parent.width
        height: compactLabel.implicitHeight

        StyledText {
            id: compactLabel
            anchors.left: parent.left
            anchors.top: parent.top
            width: 74
            text: row.meter ? row.meter.label : ""
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        Rectangle {
            anchors.left: compactLabel.right
            anchors.leftMargin: Theme.spacingXS
            anchors.right: compactReset.left
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: compactLabel.verticalCenter
            height: 4
            radius: 2
            color: Theme.surfaceContainerHighest

            Rectangle {
                width: parent.width * Math.max(0, Math.min(row.pct, 100)) / 100
                height: parent.height
                radius: 2
                color: row.accent
            }
        }

        StyledText {
            id: compactPct
            anchors.right: parent.right
            anchors.top: parent.top
            width: 32
            horizontalAlignment: Text.AlignRight
            text: row.pct + "%"
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: row.accent
        }

        // Keep reset times visible across accounts without expanding each card.
        StyledText {
            id: compactReset
            anchors.right: compactPct.left
            anchors.rightMargin: Theme.spacingS
            anchors.top: parent.top
            text: row.host && row.meter
                ? (row.host.formatSpend(row.meter) || row.host.formatResetAt(row.meter.resetAt || 0))
                : ""
            visible: text.length > 0
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
