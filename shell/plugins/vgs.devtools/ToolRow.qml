import QtQuick
import qs.Ui

// One row of the Dev Tools window, drawn from a ViewLogic row: the tool's
// icon on its tile, its name, the version or state line under it and any
// problem lines, then its chips, a channel Select when the row offers
// more than one channel, and one Button per action. The trailing group
// sits at the right while it takes at most `look.row.stackShare` of the
// text's room, and moves under the text past that, so a narrow window
// never starves the name. A problem line shows one elided line; when it
// does not fit, a Details button shows every line whole in a CodeLine the
// reader copies. A click on an action emits `acted` with the action and
// the channel the Select holds, "" for none; the window decides what runs.
// Every value the row draws itself reads `look`, the plugin's own table
// (Appearance.js).
Item {
    id: root

    // A row of ViewLogic.sections: { key, name, icon, brand, tile,
    // secondary, chips, channels, actions, lines }; null while the
    // repeater tears the row down.
    required property var row
    required property var look

    signal acted(var action, string channel)

    // What the row draws: `row`, or an empty row once it went.
    readonly property var view: row !== null ? row : ({ icon: "", brand: "", tile: "neutral", name: "", secondary: "", chips: [], channels: [], actions: [], lines: [] })
    readonly property color fill: view.tile === "brand" ? look.brand[view.brand] : view.tile === "accent" ? look.tile.accent : look.tile.neutral
    readonly property color ink: view.tile === "brand" ? look.tile.ink[view.brand] : view.tile === "accent" ? look.tile.accentInk : look.tile.neutralInk
    // The width right of the tile, and whether the trailing group moves
    // under the text.
    readonly property real room: Math.max(0, width - tile.width - look.row.gap)
    readonly property bool stacked: trailing.implicitWidth > 0 && trailing.implicitWidth > room * look.row.stackShare
    property bool detailsOpen: false
    readonly property bool clipped: {
        for (let i = 0; i < lineRepeater.count; i++) {
            const line = lineRepeater.itemAt(i);
            if (line !== null && line.truncated) return true;
        }
        return false;
    }
    readonly property real bodyHeight: stacked ? texts.implicitHeight + look.row.gap + trailing.implicitHeight : Math.max(texts.implicitHeight, trailing.implicitHeight)

    implicitHeight: Math.max(look.row.height, Math.max(tile.height, bodyHeight) + 2 * look.row.paddingY)

    Rectangle {
        id: tile
        x: 0
        y: root.stacked ? root.look.row.paddingY : Math.round((root.height - height) / 2)
        width: root.look.tile.size
        height: root.look.tile.size
        radius: root.look.tile.radius
        color: root.fill

        Icon {
            anchors.centerIn: parent
            name: root.view.icon
            size: root.look.tile.glyph
            color: root.ink
        }
    }

    Column {
        id: texts
        x: tile.width + root.look.row.gap
        y: root.stacked ? root.look.row.paddingY : Math.round((root.height - implicitHeight) / 2)
        width: root.stacked ? root.room : Math.max(0, root.room - trailing.implicitWidth - root.look.row.gap)
        spacing: root.look.row.lineGap

        Label {
            width: parent.width
            role: "item"
            text: root.view.name
            elide: Text.ElideRight
        }
        Label {
            width: parent.width
            role: "itemHint"
            text: root.view.secondary
            visible: text !== ""
            elide: Text.ElideRight
        }
        Repeater {
            id: lineRepeater
            model: root.view.lines
            Label {
                required property string modelData
                width: texts.width
                role: "hint"
                text: modelData
                visible: !root.detailsOpen
                elide: Text.ElideRight
            }
        }
        Repeater {
            model: root.detailsOpen ? root.view.lines : []
            CodeLine {
                required property string modelData
                width: texts.width
                text: modelData
                copyLabel: "Copy the detail"
            }
        }
        Button {
            visible: root.clipped || root.detailsOpen
            size: "sm"
            variant: "tertiary"
            iconName: root.detailsOpen ? "chevron-up" : "chevron-down"
            text: root.detailsOpen ? "Hide details" : "Details"
            onClicked: root.detailsOpen = !root.detailsOpen
        }
    }

    Row {
        id: trailing
        x: root.stacked ? texts.x : root.width - implicitWidth
        y: root.stacked ? texts.y + texts.implicitHeight + root.look.row.gap : Math.round((root.height - implicitHeight) / 2)
        spacing: root.look.row.actionGap

        Repeater {
            model: root.view.chips
            Badge {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text
                tone: modelData.tone
            }
        }
        Select {
            id: channel
            anchors.verticalCenter: parent.verticalCenter
            visible: root.view.channels.length > 0
            model: root.view.channels
        }
        Repeater {
            model: root.view.actions
            Button {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                size: "sm"
                variant: modelData.variant
                text: modelData.label
                onClicked: root.acted(modelData, channel.visible ? channel.currentText : "")
            }
        }
    }
}
