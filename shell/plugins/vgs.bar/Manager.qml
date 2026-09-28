import QtQuick
import qs.Commons
import qs.Ui
import "Reply.js" as Reply

// The plugin manager's button. A click opens the bar's own manager panel
// under the button, or closes it when it is open. It draws like a workspace
// pill: `text.bar` for its text, `bar.item` for its padding, its icon gap
// and its corner, its content's height plus `space.xs` tall, with the icon
// and the text on the button's vertical centre and the button on the bar's.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: button.implicitWidth
    implicitHeight: Theme.bar.height

    // Open or close the manager panel under this button; answers the
    // panel host's reply.
    function toggle() {
        const reply = root.bar.shell.surfaces.toggle("panel", "{}", root);
        if (!Reply.isOk(reply)) console.warn("manager button: panel " + reply);
        return reply;
    }

    Button {
        id: button
        anchors.centerIn: parent
        variant: "ghost"
        iconName: "layout-grid"
        text: "Plugins"
        leftPadding: Theme.bar.item.paddingX
        rightPadding: Theme.bar.item.paddingX
        topPadding: Theme.space.xs / 2
        bottomPadding: Theme.space.xs / 2
        implicitHeight: implicitContentHeight + topPadding + bottomPadding
        spacing: Theme.bar.item.iconGap
        onClicked: root.toggle()

        contentItem: Row {
            spacing: button.spacing
            Icon {
                name: button.iconName
                size: Theme.icon.size.sm
                color: button.foreground
                anchors.verticalCenter: parent.verticalCenter
            }
            Label {
                role: "bar"
                text: button.text
                color: button.foreground
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Binding { target: button.background; property: "radius"; value: Theme.bar.item.radius }
    }
}
