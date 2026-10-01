import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

// One option of a set. Radios under one parent are exclusive, as the
// template makes them: checking one unchecks its siblings. A click, Space
// or Enter checks the focused one.
T.RadioButton {
    id: root

    property bool focusPreview: false
    readonly property var radioSiblings: parent === null ? [root] : parent.children.filter(child => child !== null && child !== undefined && child.checked !== undefined && child.autoExclusive === true)
    readonly property int radioIndex: radioSiblings.indexOf(root)
    readonly property bool rovingTabStop: {
        const checkedIndex = radioSiblings.findIndex(child => child.checked && child.enabled && child.visible);
        if (checkedIndex !== -1) return radioIndex === checkedIndex;
        return radioIndex === radioSiblings.findIndex(child => child.enabled && child.visible);
    }

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(Theme.size.control.sm, implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.radio.gap
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    activeFocusOnTab: rovingTabStop
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text
    Keys.onPressed: event => { event.accepted = nav.handle(event); }

    property KeyNav nav: KeyNav {
        count: root.radioSiblings.length
        currentIndex: root.radioIndex
        orientation: "both"
        wrap: true
        reachable: index => root.radioSiblings[index].enabled && root.radioSiblings[index].visible
        onMoved: index => {
            root.radioSiblings[index].forceActiveFocus(Qt.TabFocusReason);
            KeyNavLogic.activate(root.radioSiblings[index]);
        }
        onActivated: index => KeyNavLogic.activate(root.radioSiblings[index])
    }

    indicator: Rectangle {
        implicitWidth: Theme.radio.size
        implicitHeight: Theme.radio.size
        y: root.contentItem.indicatorY(height)
        radius: Theme.radius.full
        color: root.down ? Theme.radio.pressed : Theme.radio.background
        border.width: Theme.radio.border
        border.color: root.checked ? (root.down ? Theme.radio.checkedPressed : root.hovered ? Theme.radio.checkedHover : Theme.radio.checked) : root.hovered || root.down ? Theme.radio.hoverBorder : Theme.radio.borderColor

        Rectangle {
            anchors.centerIn: parent
            width: Theme.radio.dot
            height: Theme.radio.dot
            radius: Theme.radius.full
            color: Theme.radio.checked
            visible: root.checked
        }

        FocusRing { target: root }
    }

    contentItem: IndicatorLabel { control: root }
}
