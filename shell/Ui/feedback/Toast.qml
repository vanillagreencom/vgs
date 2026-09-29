import QtQuick
import qs.Commons
import qs.Ui

// One notice in the toast stack: an icon for its tone, a title, an
// optional message and a close button. `tone` names a group of
// `Theme.badge.tone` for the icon's colour; an unknown tone is logged and
// drawn neutral. `dismissed` fires when the user closes it; the host
// owns its timer and removes it.
Rectangle {
    id: root

    property string title: ""
    property string message: ""
    property string tone: "neutral"
    property string iconName: ""
    readonly property var tokens: toneOf(tone)
    readonly property alias closeButton: close
    readonly property real basePadding: Theme.toast.padding
    readonly property real baseRadius: Theme.toast.radius
    readonly property real clearanceStep: Theme.space.xs
    property real horizontalInset: basePadding
    property bool insetSettlePending: false
    signal dismissed()

    function toneOf(name) {
        const found = Theme.badge.tone[name];
        if (found !== undefined) return found;
        console.error("Toast: no tone named " + JSON.stringify(name));
        return Theme.badge.tone.neutral;
    }

    function targetInset() {
        return Inset.clearing(basePadding, baseRadius, width, implicitHeight, clearanceStep);
    }

    function scheduleInsetSettle() {
        if (insetSettlePending) return;
        insetSettlePending = true;
        Qt.callLater(settleInset);
    }

    function resetInset() {
        horizontalInset = basePadding;
        scheduleInsetSettle();
    }

    function settleInset() {
        insetSettlePending = false;
        if (typeof root.targetInset !== "function") return;
        const next = Math.ceil(root.targetInset());
        if (Math.abs(horizontalInset - next) <= 0.01) return;
        horizontalInset = next;
        scheduleInsetSettle();
    }

    implicitWidth: Theme.toast.width
    implicitHeight: row.implicitHeight + 2 * basePadding
    radius: baseRadius
    color: Theme.toast.background
    border.width: Theme.border.thin
    border.color: Theme.toast.border
    Component.onCompleted: scheduleInsetSettle()
    onImplicitHeightChanged: scheduleInsetSettle()
    onWidthChanged: resetInset()
    onTitleChanged: resetInset()
    onMessageChanged: resetInset()
    onBasePaddingChanged: resetInset()
    onBaseRadiusChanged: resetInset()
    onClearanceStepChanged: resetInset()

    Row {
        id: row
        x: root.horizontalInset
        y: root.basePadding
        width: parent.width - 2 * root.horizontalInset
        spacing: Theme.toast.contentGap

        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.md
            color: root.tokens.foreground
        }
        Column {
            width: parent.width - (parent.children[0].visible ? parent.children[0].width + parent.spacing : 0) - close.width - parent.spacing
            spacing: Theme.space.xxs
            Label {
                role: "bodyStrong"
                text: root.title
                width: parent.width
                wrapMode: Text.Wrap
            }
            Label {
                role: "hint"
                text: root.message
                visible: root.message !== ""
                width: parent.width
                wrapMode: Text.Wrap
            }
        }
        IconButton {
            id: close
            iconName: "x"
            label: "Dismiss"
            size: "sm"
            onClicked: root.dismissed()
        }
    }
}
