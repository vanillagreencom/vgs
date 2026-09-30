import QtQuick
import qs.Ui

// The pointer flyout: a small glass menu that opens at a point and closes
// on a pick, Escape (through close()) or a click outside. Put it in a
// full-size parent. `items` is [{ id, label, icon?, glyph?, detail?,
// separator? }]: `icon` an image URL, `glyph` a Lucide name. The hovered
// entry holds a ListCursor at `motion`, the launcher's list motion, so one
// plate glides between entries.
Item {
    id: menu

    required property var look
    required property var motion
    property var items: []
    readonly property bool opened: state === "open"
    property int hovered: -1
    property point anchorPoint: Qt.point(0, 0)
    signal triggered(string id)

    anchors.fill: parent
    visible: panel.opacity > 0
    z: 100

    function openAt(px, py) {
        anchorPoint = Qt.point(px, py);
        reclamp();
        hovered = -1;
        state = "open";
    }

    // Keeps the flyout on screen; called again when `items` changes its size.
    function reclamp() {
        const px = anchorPoint.x, py = anchorPoint.y;
        const w = panel.width, h = panel.implicitHeight, m = look.flyout.margin;
        const flip = py + h + m > height;
        panel.x = Math.max(m, Math.min(px, width - w - m));
        panel.y = flip ? Math.max(m, py - h) : py;
        panel.transformOrigin = flip ? Item.BottomLeft : Item.TopLeft;
    }

    function close() { state = ""; }

    onItemsChanged: if (opened) Qt.callLater(reclamp)

    // The click-away catcher also takes hover, so nothing behind the flyout
    // reacts to the pointer while it is open.
    // pointer-cursor-exempt: a press here is a click away from the flyout, not a control
    MouseArea {
        anchors.fill: parent
        enabled: menu.opened
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
    }

    GlassSurface {
        id: panel
        look: menu.look
        width: menu.look.flyout.width
        height: implicitHeight
        implicitHeight: column.implicitHeight + 2 * menu.look.flyout.padding
        radius: menu.look.flyout.radius
        elevation: menu.look.shadow.tight
        opacity: menu.opened ? 1 : 0
        scale: menu.opened ? 1 : menu.look.flyout.openScale
        Behavior on opacity {
            Anim { duration: menu.look.motion.duration.short3; curve: menu.look.motion.curve.standard }
        }
        Behavior on scale {
            Anim { duration: menu.look.motion.duration.medium1; curve: menu.look.motion.curve.emphasizedDecel }
        }

        // The whole flyout owns the pointer, gaps and separators included.
        // pointer-cursor-exempt: it holds the presses on the flyout's gaps, where nothing is clickable
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onEntered: menu.hovered = -1
        }

        // The entries and their cursor, in an item that draws nothing:
        // the glass body paints its fill, which would cover the cursor.
        Item {
            anchors.fill: parent

            ListCursor {
                id: plate
                motion: menu.motion
                background: Highlight { look: menu.look; radius: menu.look.radius.sm }
            }

            Column {
                id: column
                x: menu.look.flyout.padding
                y: menu.look.flyout.padding
                width: parent.width - 2 * menu.look.flyout.padding

                Repeater {
                    model: menu.items

                    Item {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool separator: !!modelData.separator
                        readonly property bool hasIcon: !separator && (!!modelData.icon || !!modelData.glyph)
                        readonly property bool hasCursor: menu.hovered === index
                        onHasCursorChanged: plate.follow(entry, hasCursor)

                        width: column.width
                        height: separator ? menu.look.flyout.separatorHeight : menu.look.flyout.rowHeight

                        Rectangle {
                            visible: entry.separator
                            anchors.centerIn: parent
                            width: parent.width - menu.look.flyout.separatorInset
                            height: menu.look.glass.hairlineWidth
                            color: menu.look.glass.divider
                        }

                        Item {
                            id: iconBox
                            visible: entry.hasIcon
                            anchors.left: parent.left
                            anchors.leftMargin: menu.look.flyout.iconInset
                            anchors.verticalCenter: parent.verticalCenter
                            width: menu.look.flyout.iconSize
                            height: menu.look.flyout.iconSize

                            Image {
                                anchors.fill: parent
                                visible: !!entry.modelData.icon
                                sourceSize.width: width * Screen.devicePixelRatio
                                sourceSize.height: height * Screen.devicePixelRatio
                                source: entry.modelData.icon || ""
                                asynchronous: true
                            }
                            Icon {
                                anchors.centerIn: parent
                                visible: !entry.modelData.icon && !!entry.modelData.glyph
                                name: entry.modelData.glyph || ""
                                size: menu.look.flyout.iconSize
                                stroke: menu.look.tile.stroke
                                color: menu.look.text.foreground
                            }
                        }

                        Text {
                            visible: !entry.separator
                            anchors.left: iconBox.visible ? iconBox.right : parent.left
                            anchors.leftMargin: iconBox.visible ? menu.look.flyout.iconGap : menu.look.flyout.textInset
                            anchors.right: detail.left
                            anchors.rightMargin: menu.look.flyout.detailGap
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: entry.modelData.label || ""
                            color: menu.look.text.foreground
                            elide: Text.ElideRight
                            font.family: menu.look.font.family
                            font.pixelSize: menu.look.text.flyout.size
                        }

                        Text {
                            id: detail
                            visible: !entry.separator && !!entry.modelData.detail
                            anchors.right: parent.right
                            anchors.rightMargin: menu.look.flyout.textInset
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: entry.modelData.detail || ""
                            color: menu.look.text.foreground
                            opacity: menu.look.text.detail.opacity
                            font.family: menu.look.font.family
                            font.pixelSize: menu.look.text.flyout.detail
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !entry.separator
                            hoverEnabled: true
                            PointerCursor {}
                            onEntered: menu.hovered = entry.index
                            onExited: if (menu.hovered === entry.index) menu.hovered = -1
                            onClicked: {
                                menu.close();
                                menu.triggered(entry.modelData.id);
                            }
                        }
                    }
                }
            }
        }
    }
}
