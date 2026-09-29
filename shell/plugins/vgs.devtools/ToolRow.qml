import QtQuick
import qs.Ui

// One row of the Dev Tools panel, drawn from a ViewLogic row: the tool's
// icon on its tile, its name, the version or state line under it and any
// problem lines, then its chips, a channel Select when the row offers
// more than one channel, and one Button per action. A click on an action
// emits `acted` with the action and the channel the Select holds, "" for
// none; the panel decides what runs. Every value the row draws itself
// reads `look`, the plugin's own table (Appearance.js).
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

    implicitHeight: Math.max(tile.height, texts.implicitHeight, trailing.implicitHeight) + 2 * look.row.paddingY

    Rectangle {
        id: tile
        x: root.look.row.paddingX
        anchors.verticalCenter: parent.verticalCenter
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
        anchors.left: tile.right
        anchors.leftMargin: root.look.row.gap
        anchors.right: trailing.left
        anchors.rightMargin: root.look.row.gap
        anchors.verticalCenter: parent.verticalCenter
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
            model: root.view.lines
            Label {
                required property string modelData
                width: texts.width
                role: "hint"
                text: modelData
                wrapMode: Text.Wrap
            }
        }
    }

    Row {
        id: trailing
        anchors.right: parent.right
        anchors.rightMargin: root.look.row.paddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.look.row.lineGap

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
