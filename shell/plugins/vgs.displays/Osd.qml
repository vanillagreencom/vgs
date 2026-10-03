import QtQuick
import qs.Commons
import qs.Ui

// The brightness on-screen display, one copy per screen in the plugin's
// passive layer: a LevelOsd low in the middle of the screen, mapped only
// on the screens whose display the last key or scroll changed, while the
// service shows it. It takes no focus and no press.
Item {
    id: root

    // The core assigns the copy's screen; the service owns what it shows.
    property var screen: null
    property var service: null
    readonly property string screenName: screen ? screen.name : ""
    readonly property bool shown: service !== null && service.osd.shown && service.osd.outputs.indexOf(screenName) !== -1

    LevelOsd {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space.xxxl
        iconName: "sun"
        level: root.service === null ? 0 : root.service.osd.percent / 100
    }
}
