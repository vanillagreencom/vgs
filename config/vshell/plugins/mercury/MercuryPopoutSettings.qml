import QtQuick
import qs.Common
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryOptions.js" as Opt

// The popout's own settings page — the second half of the pager, reached from
// the gear in the header and left with the back arrow.
//
// Two cards, not one card and three loose blocks. Every group sits on the same
// surface at the same inset, so the page has one rhythm; before this the key
// panel was contained and the three choice rows floated against the popout
// background, which read as three afterthoughts under a card.
//
// It writes the same plugin data the settings application's page writes, and
// renders its choices from the same option lists in MercuryLogic.js, so the
// two surfaces cannot offer different sets or disagree about what is selected.
Column {
    id: root

    required property var widget

    width: parent.width
    spacing: Theme.spacingM

    function save(key, value) {
        if (root.widget.pluginService)
            root.widget.pluginService.savePluginData("mercury", key, value);
    }

    StyledRect {
        width: parent.width
        height: keyPanel.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        MercuryKeyPanel {
            id: keyPanel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingL
            anchors.rightMargin: Theme.spacingL

            onKeyChanged: root.save("keyChangedAt", Date.now())
        }
    }

    StyledRect {
        width: parent.width
        height: optionsColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: optionsColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingL
            anchors.rightMargin: Theme.spacingL
            spacing: Theme.spacingM

            // No descriptions. Every option carries its own label — "24h / 5d
            // / …", "$3,701.86 / $3,702 / $3.7K / Hidden" — which says more
            // than a sentence above the row would.
            MercuryOptionRow {
                width: parent.width
                label: I18n.tr("Activity window")
                options: Opt.daysOptions()
                current: String(root.widget.days)
                onPicked: value => root.save("days", value)
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outlineLight
            }

            MercuryOptionRow {
                width: parent.width
                label: I18n.tr("Bar display")
                options: Opt.pillModeOptions()
                current: root.widget.pillMode
                onPicked: value => root.save("pillMode", value)
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outlineLight
            }

            MercuryOptionRow {
                width: parent.width
                label: I18n.tr("Refresh")
                options: Opt.refreshOptions()
                current: String(Math.round(root.widget.refreshMs / 1000))
                onPicked: value => root.save("refreshSeconds", value)
            }
        }
    }
}
