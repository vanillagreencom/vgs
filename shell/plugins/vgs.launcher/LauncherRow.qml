import QtQuick
import Quickshell
import qs.Ui

// One row of the launcher's list: an icon tile or an application's own
// icon, the label, the detail line while a search narrows the list, and a
// chevron on a menu. The row that holds the cursor hands itself to the
// list's ListCursor, so one plate glides between rows, and a row new since
// the last rebuild enters through ListEntrance.
Item {
    id: row

    required property var look
    // The launcher: its state and the functions a row calls.
    required property var launcher
    required property ListCursor plate

    required property int index
    required property string itemId
    required property string kind
    required property string icon
    required property string appIcon
    required property string label
    required property string target
    required property string detail
    required property string path
    required property int childCount
    required property string section

    // The first search hit outside the current menu draws a hairline in the
    // gap above it, so every row keeps one pitch.
    // The launcher and the list go before their delegates as the overlay
    // is destroyed, so every binding on them reads them through a guard.
    readonly property bool live: launcher !== null && ListView.view !== null
    readonly property bool startsDrilldown: live && section === "drilldown" && index > 0 && ListView.view.model.get(index - 1).section !== "drilldown"
    readonly property bool hasCursor: live && launcher.cursorActive && index === launcher.selectedIndex
    readonly property bool imageIcon: kind === "app" || kind === "file" || kind === "folder" || (kind === "openwith" && appIcon.length > 0)
    readonly property bool hasIcon: icon.length > 0 || imageIcon
    readonly property bool isMenu: kind === "menu" || kind === "link"
    readonly property bool showsDetail: live && (launcher.filterText.length > 0 || kind === "option" || kind === "notice" || kind === "unavailable") && detail.length > 0

    height: live ? launcher.rowHeightFor(detail) : 0

    // A row new since the last rebuild rises in, or slides in from the
    // side the menu change came from.
    opacity: entrance.progress
    transform: ListEntrance {
        id: entrance
        shift: row.look.row.enterX
        // The launcher goes before its rows as the overlay is destroyed;
        // the entrance keeps the motion it last had.
        Binding on motion { when: row.live; value: row.live ? row.launcher.listMotion : null; restoreMode: Binding.RestoreNone }
    }
    Component.onCompleted: {
        if (hasCursor) plate.follow(row, true);
        if (live && launcher.freshIds[itemId]) entrance.start(plate.enterSlot(), launcher.navDirection);
    }
    onHasCursorChanged: if (plate !== null) plate.follow(row, hasCursor)

    Rectangle {
        visible: row.startsDrilldown
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: row.look.row.dividerInset
        anchors.rightMargin: row.look.row.dividerInset
        y: -Math.ceil(row.look.row.spacing / 2) - row.look.glass.hairlineWidth
        height: row.look.glass.hairlineWidth
        color: row.look.glass.divider
    }

    IconTile {
        id: tile
        look: row.look
        visible: row.hasIcon && !row.imageIcon
        anchors.left: parent.left
        anchors.leftMargin: row.look.row.iconInset
        anchors.verticalCenter: parent.verticalCenter
        iconName: row.icon
        active: row.hasCursor
    }

    Image {
        visible: row.imageIcon
        width: tile.width
        height: tile.height
        fillMode: Image.PreserveAspectFit
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: row.kind === "app" ? (row.appIcon ? Quickshell.iconPath(row.appIcon, true) : "") : row.appIcon
        asynchronous: true
        anchors.left: parent.left
        anchors.leftMargin: row.look.row.iconInset
        anchors.verticalCenter: parent.verticalCenter
    }

    Column {
        anchors.left: row.hasIcon ? tile.right : parent.left
        anchors.leftMargin: row.hasIcon ? row.look.row.textGap : row.look.row.textInset
        anchors.right: chevron.left
        anchors.rightMargin: row.look.row.textRight
        anchors.verticalCenter: parent.verticalCenter
        spacing: row.look.row.lineGap

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: row.label
            color: row.look.text.foreground
            opacity: row.hasCursor ? 1 : row.look.text.label.rest
            font.family: row.look.font.family
            font.pixelSize: row.look.text.label.size
            font.weight: row.look.text.label.weight
            style: Text.Raised
            styleColor: row.look.text.shadow
            elide: Text.ElideRight
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: row.detail
            visible: row.showsDetail
            color: row.look.text.foreground
            opacity: row.look.text.detail.opacity
            font.family: row.look.font.family
            font.pixelSize: row.look.text.detail.size
            elide: Text.ElideRight
        }
    }

    ChevronGlyph {
        id: chevron
        look: row.look
        anchors.right: parent.right
        anchors.rightMargin: row.look.chevron.inset
        anchors.verticalCenter: parent.verticalCenter
        opacity: row.isMenu ? (row.hasCursor ? row.look.chevron.active : row.look.chevron.idle) : 0
        Behavior on opacity {
            Anim { duration: row.look.motion.duration.short4; curve: row.look.motion.curve.standard }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        PointerCursor {}
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: row.launcher.selectFromPointer(row.index, row, { x: mouseX, y: mouseY })
        onPositionChanged: mouse => row.launcher.selectFromPointer(row.index, row, mouse)
        onClicked: mouse => {
            row.launcher.cursorActive = true;
            row.launcher.selectedIndex = row.index;
            if (mouse.button === Qt.RightButton) {
                if (row.kind === "file" || row.kind === "folder") {
                    const at = mapToItem(row.launcher, mouse.x, mouse.y);
                    row.launcher.openFileFlyout(row.path, row.label, at.x, at.y);
                }
                return;
            }
            row.launcher.activateIndex(row.index, true);
        }
    }
}
