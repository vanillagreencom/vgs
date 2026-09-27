import QtQuick
Item {
    property var shell: null
    property var screen: null
    readonly property string screenName: screen === null ? "" : screen.name
}
