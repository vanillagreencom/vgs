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

    // Display-facing authentication state. Written only by the primary
    // GreeterContent — the one instance whose Greetd Connections are enabled —
    // and read by every rendered copy. It lives here rather than on
    // GreeterContent so the login prompt mirrored onto other screens shows the
    // same spinner, buttons and failure message instead of a blank one.
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
