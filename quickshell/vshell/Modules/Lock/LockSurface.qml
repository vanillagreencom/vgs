pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Wayland
import qs.Common
import qs.Services

FocusScope {
    id: root

    required property WlSessionLock lock
    required property var pam
    required property string sharedPasswordBuffer
    required property string screenName
    required property bool isLocked

    signal passwordChanged(string newPassword)
    signal unlockRequested

    function notifyActivity() {
        if (!isLocked || activityThrottle.running)
            return;
        IdleService.notifyActivity();
        activityThrottle.restart();
    }

    Keys.onPressed: event => {
        notifyActivity();
        if (videoScreensaver.active && videoScreensaver.inputEnabled) {
            videoScreensaver.dismiss();
            event.accepted = true;
        }
    }

    Timer {
        id: activityThrottle
        interval: 150
        repeat: false
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
    }

    LockScreenContent {
        id: lockContent

        anchors.fill: parent
        demoMode: false
        pam: root.pam
        passwordBuffer: root.sharedPasswordBuffer
        screenName: root.screenName
        enabled: !videoScreensaver.active
        focus: !videoScreensaver.active
        opacity: videoScreensaver.active ? 0 : 1
        onActivity: root.notifyActivity()
        onUnlockRequested: root.unlockRequested()
        onPasswordEdited: text => root.passwordChanged(text)

        Behavior on opacity {
            NumberAnimation {
                duration: 200
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        z: 1000
        enabled: root.isLocked
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.notifyActivity()
        onPositionChanged: root.notifyActivity()
        onWheel: wheel => {
            root.notifyActivity();
            wheel.accepted = false;
        }
    }

    VideoScreensaver {
        id: videoScreensaver
        anchors.fill: parent
        screenName: root.screenName
        onDismissed: Qt.callLater(() => lockContent.focusPasswordField())
    }

    // Full-black blank state after idle-while-locked. Monitors stay powered on
    // (this is NOT DPMS) — it just covers the lock content/screensaver. Input still
    // reaches the MouseArea/Keys below (a plain Rectangle captures nothing), so any
    // activity un-idles IdleService's blank tier and this fades out to the prompt.
    Rectangle {
        anchors.fill: parent
        z: 2000
        color: "black"
        visible: opacity > 0
        opacity: (root.isLocked && IdleService.lockScreenBlanked) ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 400
            }
        }

        // Hide the pointer while the screen reads as off. acceptedButtons: NoButton
        // keeps the "captures nothing" promise above — presses and hover still fall
        // through to the handlers below, so any activity un-blanks as before.
        MouseArea {
            anchors.fill: parent
            enabled: parent.opacity > 0 && SettingsData.hideCursorWhenBlanked
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.BlankCursor
        }
    }

    Connections {
        target: IdleService
        function onLockScreenBlankedChanged() {
            // Going black -> stop the video saver (don't run it under the overlay);
            // it stays dismissed, so waking shows the password prompt, not the saver.
            if (IdleService.lockScreenBlanked && videoScreensaver.active)
                videoScreensaver.dismiss();
        }
    }

    Component.onCompleted: forceActiveFocus()

    onIsLockedChanged: {
        if (isLocked) {
            forceActiveFocus();
            lockContent.resetLockState();
            if (SettingsData.lockScreenVideoEnabled) {
                videoScreensaver.start();
            }
            return;
        }
        lockContent.unlocking = false;
    }
}
