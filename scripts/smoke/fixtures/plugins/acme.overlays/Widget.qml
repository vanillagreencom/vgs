import QtQuick
import qs.Ui
BarWidget {
    id: root
    implicitWidth: 120
    implicitHeight: barSize
    property int triggered: -1
    readonly property bool popoverOpen: popover.opened
    readonly property bool tooltipOpen: tip.opened
    readonly property bool menuOpen: menu.opened
    readonly property bool selectOpen: select.listOpen
    readonly property int selected: select.currentIndex
    readonly property string typed: input.text
    readonly property bool inputFocus: input.activeFocus
    function openPopover() { popover.open(); return "ok"; }
    function openMenu() { menu.open(); return "ok"; }
    function openSelect() { select.openList(); return "ok"; }
    function focusInput() { input.forceActiveFocus(); return "ok"; }
    function rect(item) { const p = item.mapToGlobal(0, 0); return JSON.stringify([p.x, p.y, item.width, item.height]); }
    function geometry() { return rect(root); }
    function anchorGeometry() { return rect(anchor); }
    function selectGeometry() { return rect(select); }
    function tipTargetGeometry() { return rect(target); }
    // A popup's rectangle in the bar window's coordinates, read through an
    // item inside it, as the summon rows read a popup panel.
    function popoverGeometry() { const p = probe.mapToGlobal(0, 0); return JSON.stringify([p.x - probe.padding, p.y - probe.padding, probe.width + 2 * probe.padding, probe.height + 2 * probe.padding]); }
    function selectListGeometry() { return select.listGeometry(); }
    function moveAnchor() { holder.x += 20; return "ok"; }
    function hideAnchor() { holder.visible = false; return "ok"; }
    function showAnchor() { holder.visible = true; holder.x = 0; return "ok"; }
    function summonHere() { return shell.surfaces.summon("panel", "{}", root); }
    Item {
        id: holder
        width: 40; height: parent.height
        Item {
            id: anchor
            width: 40; height: parent.height
            Popover {
                id: popover
                width: 160
                Item {
                    id: probe
                    readonly property int padding: 8
                    width: parent.width
                    height: input.height
                    TextField { id: input; placeholderText: "type"; width: parent.width }
                }
            }
        }
    }
    Item {
        id: target
        x: 40; width: 40; height: parent.height
        Tooltip { id: tip; text: "hint" }
        Menu {
            id: menu
            MenuItem { text: "First"; onTriggered: root.triggered = 0 }
            MenuItem { text: "Second"; onTriggered: root.triggered = 1 }
        }
    }
    Select {
        id: select
        x: 80; width: 40; height: parent.height
        model: ["one", "two", "three"]
    }
}
