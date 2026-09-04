pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

Singleton {
    id: root

    property string passwordBuffer: ""
    property string username: ""
    property string usernameInput: ""
    property bool showPasswordInput: false
    property string selectedSession: ""
    property string selectedSessionPath: ""
    property string selectedSessionDesktopId: ""
    property string pamState: ""
    property bool unlocking: false

    // Shared authentication display state. The primary GreeterContent writes it; mirror screens read it.
    property bool awaitingExternalAuth: false
    property bool pendingPasswordResponse: false
    property int passwordFailureCount: 0
    property string authFeedbackMessage: ""

    property var sessionList: []
    property var sessionExecs: []
    property var sessionPaths: []
    property var sessionDesktopIds: []
    property int currentSessionIndex: 0
    property var availableUsers: []
    property int selectedUserIndex: -1

    function reset() {
        showPasswordInput = false;
        username = "";
        usernameInput = "";
        passwordBuffer = "";
        pamState = "";
        selectedUserIndex = -1;
    }
}
