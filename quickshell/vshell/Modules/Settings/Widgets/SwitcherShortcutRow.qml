pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../../../Common/KeyUtils.js" as KeyUtils

// Configure a switcher shortcut through KeybindsService so the keybind editor sees the same binding.
// KeybindCaptureField shares chord decoding with that editor.
Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    // The VGS action this row binds, e.g. "spawn vshell ipc call
    // theme-switcher toggle". Must be one of KeybindActions.js's VGS_ACTIONS,
    // or the compositor is handed a bind nothing answers.
    required property string action
    property string text: ""
    property string description: ""
    // Written into the bind so the keybinds editor and the compositor's own
    // cheatsheet have something to call it.
    property string bindDescription: ""
    property var panelWindow: null

    // `keysForAction` reads a cache the service rebuilds on load and on save;
    // `_dataVersion` is what makes that a binding rather than a one-shot read.
    readonly property int keybindDataVersion: KeybindsService._dataVersion
    readonly property bool available: KeybindsService.available
    readonly property bool readOnly: KeybindsService.readOnly
    // Saved bindings have no effect until the compositor includes the generated binds file.
    readonly property bool needsSetup: root.available && !KeybindsService.vgsBindsIncluded
    // Wait for a completed bind read before capture. loadBinds(false) does not set loading, and an empty cache hides conflicts.
    // Saving an unchecked chord would replace its existing binding.
    readonly property bool bindsReady: KeybindsService._dataVersion > 0
    // Replacing a chord removes its existing bindings. Wait for confirmation when another action owns it.
    property string pendingKey: ""
    readonly property var pendingConflicts: {
        void (root.keybindDataVersion);
        if (!root.pendingKey)
            return [];
        return KeyUtils.getConflictingBinds(root.pendingKey, root.action, KeybindsService.getFlatBinds(), KeybindsService.currentProvider === "niri" ? KeybindsService.modKey : "Super");
    }

    function commit(token) {
        // Check saving inside commit: assigning running to an active Process cannot queue another save.
        if (!token || token === root.boundKey || KeybindsService.saving || !root.bindsReady)
            return;
        // Pass originalKey so changing a chord removes the previous binding for this action.
        KeybindsService.saveBind(root.boundKey, {
            "key": token,
            "action": root.action,
            "desc": root.bindDescription || root.text
        });
        root.pendingKey = "";
    }

    readonly property string boundKey: {
        void (root.keybindDataVersion);
        if (!root.available)
            return "";
        const keys = KeybindsService.keysForAction(root.action);
        return keys.length > 0 ? keys[0] : "";
    }

    width: parent?.width ?? 0
    height: rowContent.implicitHeight + Theme.spacingS * 2
    radius: Theme.controlRadius
    color: "transparent"

    Component.onCompleted: {
        if (KeybindsService.available)
            KeybindsService.loadBinds(false);
    }

    Row {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingM

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - controls.width - Theme.spacingM
            spacing: Theme.spacingXXS

            StyledText {
                width: parent.width
                text: root.text
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignLeft
            }

            StyledText {
                width: parent.width

                text: {
                    if (!root.available)
                        return I18n.tr("Set this shortcut in your compositor config — VGS cannot write binds for it");

                    if (root.readOnly)
                        return KeybindsService.vgsStatus.statusMessage || I18n.tr("VGS reads these binds read-only — change this shortcut in your compositor config");
                    if (root.needsSetup)
                        return I18n.tr("Run Setup first — until VGS's binds file is included in your compositor config, a shortcut saved here will not load");
                    return root.description;
                }
                font.pixelSize: Theme.fontSizeSmall
                color: (root.needsSetup || root.readOnly) ? Theme.warning : Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                visible: text !== ""
                horizontalAlignment: Text.AlignLeft
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.pendingConflicts.length > 0
                // This row is outside the controls group and needs its own save-state gate.
                enabled: !KeybindsService.saving
                opacity: enabled ? 1 : 0.5

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - replaceButton.width - cancelButton.width - Theme.spacingS * 2
                    text: root.pendingConflicts.length > 0 ? I18n.tr("%1 already runs %2").arg(root.pendingKey).arg(root.pendingConflicts[0].desc) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.warning
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignLeft
                }

                VgsButton {
                    id: replaceButton
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Replace")
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: root.commit(root.pendingKey)
                }

                VgsButton {
                    id: cancelButton
                    anchors.verticalCenter: parent.verticalCenter
                    variant: "secondary"
                    text: I18n.tr("Cancel")
                    onClicked: root.pendingKey = ""
                }
            }
        }

        Row {
            id: controls
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            visible: root.available && !root.readOnly
            // Disable capture, replacement and deletion during saves. The service has one saveProcess and no queue.
            enabled: !KeybindsService.saving && root.bindsReady
            opacity: enabled ? 1 : 0.5

            VgsButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.needsSetup
                text: KeybindsService.fixing ? I18n.tr("Setting up...") : I18n.tr("Setup")
                backgroundColor: Theme.primary
                textColor: Theme.primaryText
                enabled: !KeybindsService.fixing
                onClicked: KeybindsService.fixVgsBindsInclude()
            }

            KeybindCaptureField {
                width: Math.round(Theme.fontSizeMedium * 14)
                height: Math.round(Theme.fontSizeMedium * 3)
                anchors.verticalCenter: parent.verticalCenter
                panelWindow: root.panelWindow
                readOnly: root.readOnly
                keyText: root.boundKey
                onRecordingRefused: KeybindsService.showHyprlandReadOnlyWarning()
                onCaptured: token => {
                    root.pendingKey = token;

                    if (root.pendingConflicts.length === 0)
                        root.commit(token);
                }
            }

            VgsActionButton {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(Theme.fontSizeSmall * 2.3)
                height: Math.round(Theme.fontSizeSmall * 2.3)
                circular: false
                iconName: "delete"
                iconSize: Theme.iconSizeSmall
                iconColor: Theme.error
                enabled: root.boundKey !== "" && !root.readOnly
                opacity: enabled ? 1 : 0.4
                onClicked: {
                    if (root.readOnly) {
                        KeybindsService.showHyprlandReadOnlyWarning();
                        return;
                    }
                    if (root.boundKey)
                        KeybindsService.removeBind(root.boundKey);
                }
            }
        }
    }
}
