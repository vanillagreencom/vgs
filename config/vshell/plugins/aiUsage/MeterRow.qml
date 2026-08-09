import QtQuick
import qs.Common
import qs.Widgets

// One usage meter in compact form: the collapsed per-account summary, one line
// per window — label, bar, reset clock, percentage. The full-card form of the
// same meter is MeterCard. (VGS-72)
//
// A Column, not a manually anchored Item. The old row carried its own height
// arithmetic (`compactLabel.implicitHeight + 5`), so every line added to it had
// to add a term to that expression as well as its own markup. Here the height
// is implicit and the trailing 5px is padding, so a second line costs one
// child and nothing else.
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

    // Space below the row rather than around it, so the gap reads as separation
    // from the next window and not as padding on both sides of this one.
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

        // The reset clock time belongs on the collapsed row too — otherwise it
        // is only readable one account at a time, and comparing windows across
        // accounts is the point of this view.
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
