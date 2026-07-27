import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

VgsModal {
    id: root

    property bool lockOnSwitch: false

    function showFromPowerMenu() {
        root.lockOnSwitch = false;
        SessionsService.refresh();
        open();
    }

    function showFromLockScreen() {
        root.lockOnSwitch = true;
        SessionsService.refresh();
        open();
    }

    function _formatTty(s) {
        if (s.tty && s.tty.length > 0)
            return s.tty;
        if (s.seat && s.seat.length > 0)
            return s.seat;
        return I18n.tr("remote");
    }

    function _formatType(s) {
        if (!s.type || s.type.length === 0)
            return "";
        switch (s.type) {
        case "wayland":
            return "Wayland";
        case "x11":
            return "X11";
        case "tty":
            return "TTY";
        default:
            return s.type.charAt(0).toUpperCase() + s.type.substring(1);
        }
    }

    function _doSwitch(sessionId, username) {
        if (root.lockOnSwitch && typeof SessionService !== "undefined" && SessionService.loginctlAvailable)
            SessionService.lock();
        SessionsService.activate(sessionId, null);
        close();
    }

    layerNamespace: "vshell:switch-user-modal"
    shouldBeVisible: false
    allowStacking: true
    modalWidth: 420
    // Even padding: the content column is inset spacingL from the top, so reserve
    // spacingL top + spacingL bottom (was spacingM*2, which — with the column's
    // spacingL top inset + a trailing spacer — left more room below than above).
    modalHeight: contentLoader.item ? Math.min(540, contentLoader.item.implicitHeight + Theme.spacingL * 2) : 320
    enableShadow: true
    shouldHaveFocus: true
    onBackgroundClicked: close()

    content: Component {
        Item {
            anchors.fill: parent
            implicitHeight: mainColumn.implicitHeight

            Column {
                id: mainColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    VgsIcon {
                        name: "switch_account"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: I18n.tr("Switch User")
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("Select an active session to switch to. The current session stays running in the background.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    visible: SessionsService.otherSessions().length > 0
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: SessionsService.otherSessions().length > 0

                    Repeater {
                        model: SessionsService.otherSessions()

                        Rectangle {
                            id: sessionRow
                            required property var modelData
                            width: parent.width
                            height: 64
                            radius: Theme.cornerRadius
                            // Hover brightens toward the accent (was reversed:
                            // full fill at rest, dimmed on hover).
                            color: sessionMouse.containsMouse ? Theme.blend(Theme.surfaceContainerHigh, Theme.primary, 0.16) : Theme.surfaceContainerHigh

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingM

                                VgsIcon {
                                    name: "account_circle"
                                    size: Theme.iconSize + 4
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - Theme.iconSize - 4 - chevron.width - Theme.spacingM * 2
                                    spacing: Theme.spacingXXS
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledText {
                                        text: sessionRow.modelData.username
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        text: {
                                            const tty = root._formatTty(sessionRow.modelData);
                                            const type = root._formatType(sessionRow.modelData);
                                            const parts = [];
                                            if (type)
                                                parts.push(type);
                                            parts.push(I18n.tr("session %1").arg(sessionRow.modelData.sessionId));
                                            if (tty)
                                                parts.push(tty);
                                            return parts.join(" · ");
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                VgsIcon {
                                    id: chevron
                                    name: "chevron_right"
                                    size: Theme.iconSize
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: sessionMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root._doSwitch(sessionRow.modelData.sessionId, sessionRow.modelData.username)
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: SessionsService.otherSessions().length === 0

                    Rectangle {
                        width: parent.width
                        height: bodyCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        // Passive empty-state callout: a calm fill + hairline so it
                        // reads as information, not a clickable/hoverable row.
                        color: Theme.surfaceContainerHigh
                        border.width: 1
                        border.color: Theme.borderColor

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            VgsIcon {
                                name: "info"
                                size: Theme.iconSize
                                color: Theme.surfaceVariantText
                                anchors.top: parent.top
                                anchors.topMargin: 2
                            }

                            Column {
                                id: bodyCol
                                width: parent.width - Theme.iconSize - Theme.spacingM
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: I18n.tr("No other active sessions on this seat")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    width: parent.width
                                    text: I18n.tr("To sign in as a different user, log out and pick the account from the greeter. Creating a fresh session in parallel needs a multi-session greeter (greetd-flexiserver / GDM / LightDM).")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM
                    layoutDirection: Qt.RightToLeft

                    VgsButton {
                        text: I18n.tr("Close")
                        backgroundColor: Theme.surfaceVariantAlpha
                        textColor: Theme.surfaceText
                        onClicked: root.close()
                    }

                    VgsButton {
                        visible: SessionsService.otherSessions().length === 0 && !root.lockOnSwitch
                        text: I18n.tr("Log Out")
                        iconName: "logout"
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        onClicked: {
                            if (typeof SessionService !== "undefined")
                                SessionService.logout();
                            root.close();
                        }
                    }
                }
            }
        }
    }
}
