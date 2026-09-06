pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// Scratchpad editor that emits changes to its tab, which owns configuration writes.
Column {
    id: row

    property var pad: ({})
    property int padIndex: 0
    property int padCount: 1
    property bool expanded: false
    property bool capturing: false
    property string conflict: ""
    // Pattern evaluation: {state, count, error}, or null before a request. Unknown and error are not zero matches.
    property var matchState: null
    readonly property string matchKind: (matchState && matchState.state) || "unknown"
    readonly property int matchCount: (matchState && matchState.count) || 0
    // Set when automatic class matching was asked for but could not be honoured.
    property string autoNote: ""
    // Set when a manually typed class pattern was refused.
    property string regexNote: ""
    // True while an async operation the tab started is still in flight, so the
    // controls that would start another one are held.
    property bool busy: false
    // The tab owns the option/value tables and the keybind normalization; this
    // component reads them rather than keeping a second copy that could drift.
    property var tabRoot: null

    signal toggleExpand
    signal requestCapture
    signal captureFinished(string combo)
    signal changePad(var changes)
    signal setEnabled(bool enabled)
    signal remove
    signal move(int delta)

    spacing: 0

    StyledRect {
        width: parent.width
        height: summary.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: summaryArea.containsMouse || row.expanded ? Theme.surfaceContainerHigh : Theme.surfaceContainer

        MouseArea {
            id: summaryArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.toggleExpand()
        }

        Item {
            id: summary
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            implicitHeight: Math.max(labels.implicitHeight, controls.implicitHeight)

            Column {
                id: labels
                anchors.left: parent.left
                anchors.right: controls.left
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    width: parent.width
                    text: row.pad.name || row.pad.id || ""
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: row.pad.enabled === false ? Theme.surfaceVariantText : Theme.surfaceText
                }

                StyledText {
                    width: parent.width

                    text: (row.pad.classRegex || "") + (row.pad.keybind ? "  ·  " + row.pad.keybind : "")
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.settingsFontSize
                    font.family: Theme.monoFontFamily
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    visible: row.conflict.length > 0
                    text: row.conflict
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.error
                }

                // Failed pattern evaluation cannot report a match count.
                StyledText {
                    width: parent.width
                    visible: row.matchKind === "error"
                    text: I18n.tr("Could not check this pattern: %1").arg((row.matchState && row.matchState.error) || I18n.tr("unknown error"))
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.error
                }


                StyledText {
                    width: parent.width
                    visible: row.matchKind === "known" && row.matchCount > 1
                    text: I18n.tr("%1 open windows match this pattern — the scratchpad will claim all of them.").arg(row.matchCount)
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.warning
                }

                // Show zero only for a known count. It can mean either a closed pad or a pattern that misses its window.
                StyledText {
                    width: parent.width
                    visible: row.matchKind === "known" && row.matchCount === 0 && (row.pad.classRegex || "").length > 0
                    text: I18n.tr("No open window matches this pattern.")
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                }
            }

            Row {
                id: controls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                VgsActionButton {
                    iconName: "keyboard_arrow_up"
                    enabled: row.padIndex > 0
                    onClicked: row.move(-1)
                }

                VgsActionButton {
                    iconName: "keyboard_arrow_down"
                    enabled: row.padIndex < row.padCount - 1
                    onClicked: row.move(1)
                }

                VgsActionButton {
                    iconName: "delete"
                    // Removing waits on a release before the record goes away;
                    // until that answers, the row is mid-operation.
                    enabled: !row.busy
                    onClicked: row.remove()
                }

                VgsToggle {
                    checked: row.pad.enabled !== false
                    // Disabling must hide the pad before removing its keybind. Hold the control while the tab completes that operation.
                    enabled: !row.busy
                    onToggled: checked => row.setEnabled(checked)
                }
            }
        }
    }


    Column {
        width: parent.width
        visible: row.expanded
        topPadding: Theme.spacingM
        bottomPadding: Theme.spacingM
        leftPadding: Theme.spacingM
        spacing: Theme.spacingM

        SettingsDropdownRow {
            text: I18n.tr("Monitor")
            description: I18n.tr("Which output the pad opens on")
            options: row.tabRoot ? row.tabRoot.monitorOptions : []
            currentValue: row.tabRoot ? row.tabRoot.labelFor(row.tabRoot.monitorOptions, row.tabRoot.monitorValues, row.pad.monitor || "", 0) : ""
            onValueChanged: value => {
                const index = row.tabRoot.monitorOptions.indexOf(value);
                if (index >= 0)
                    row.changePad({
                        "monitor": row.tabRoot.monitorValues[index]
                    });
            }
        }

        SettingsDropdownRow {
            text: I18n.tr("Presentation")
            description: I18n.tr("Fullscreen fills the pad's own hidden workspace — for VM viewers and full-screen web apps")
            options: row.tabRoot ? row.tabRoot.presentationOptions : []
            currentValue: row.tabRoot ? row.tabRoot.labelFor(row.tabRoot.presentationOptions, row.tabRoot.presentationValues, row.pad.presentation || "float", 0) : ""
            onValueChanged: value => {
                const index = row.tabRoot.presentationOptions.indexOf(value);
                if (index >= 0)
                    row.changePad({
                        "presentation": row.tabRoot.presentationValues[index]
                    });
            }
        }

        // Size and position only mean anything for a floating pad; a tiled or
        // fullscreen one is laid out by the compositor.
        Column {
            width: parent.width
            spacing: Theme.spacingM
            visible: (row.pad.presentation || "float") === "float"

            SettingsToggleRow {
                text: I18n.tr("Size in pixels")
                description: I18n.tr("Percentages follow the monitor and are right on every display. Use pixels only for an app with a hard minimum size.")
                checked: (row.pad.sizeMode || "percent") === "pixels"
                onToggled: checked => row.changePad({
                        "sizeMode": checked ? "pixels" : "percent"
                    })
            }

            SettingsSliderRow {
                visible: (row.pad.sizeMode || "percent") !== "pixels"
                text: I18n.tr("Width")
                unit: "%"
                minimum: 5
                maximum: 100
                value: row.pad.widthPercent !== undefined ? row.pad.widthPercent : 60
                onSliderDragFinished: newValue => row.changePad({
                        "widthPercent": newValue
                    })
            }

            SettingsSliderRow {
                visible: (row.pad.sizeMode || "percent") !== "pixels"
                text: I18n.tr("Height")
                unit: "%"
                minimum: 5
                maximum: 100
                value: row.pad.heightPercent !== undefined ? row.pad.heightPercent : 70
                onSliderDragFinished: newValue => row.changePad({
                        "heightPercent": newValue
                    })
            }

            SettingsSliderRow {
                visible: (row.pad.sizeMode || "percent") === "pixels"
                text: I18n.tr("Width")
                unit: "px"
                minimum: 160
                maximum: 3840
                step: 10
                value: row.pad.widthPixels !== undefined ? row.pad.widthPixels : 1200
                onSliderDragFinished: newValue => row.changePad({
                        "widthPixels": newValue
                    })
            }

            SettingsSliderRow {
                visible: (row.pad.sizeMode || "percent") === "pixels"
                text: I18n.tr("Height")
                unit: "px"
                minimum: 120
                maximum: 2160
                step: 10
                value: row.pad.heightPixels !== undefined ? row.pad.heightPixels : 800
                onSliderDragFinished: newValue => row.changePad({
                        "heightPixels": newValue
                    })
            }

            SettingsDropdownRow {
                text: I18n.tr("Anchor")
                description: I18n.tr("VGS computes the coordinates from the anchor, the size and the monitor")
                options: row.tabRoot ? row.tabRoot.anchorOptions : []
                currentValue: row.tabRoot ? row.tabRoot.labelFor(row.tabRoot.anchorOptions, row.tabRoot.anchorValues, row.pad.anchor || "top-center", 1) : ""
                onValueChanged: value => {
                    const index = row.tabRoot.anchorOptions.indexOf(value);
                    if (index >= 0)
                        row.changePad({
                            "anchor": row.tabRoot.anchorValues[index]
                        });
                }
            }

            SettingsSliderRow {
                text: I18n.tr("Offset X")
                description: I18n.tr("Measured inward from the anchored edge")
                unit: "px"
                minimum: 0
                maximum: 600
                value: row.pad.offsetX !== undefined ? row.pad.offsetX : 0
                onSliderDragFinished: newValue => row.changePad({
                        "offsetX": newValue
                    })
            }

            SettingsSliderRow {
                text: I18n.tr("Offset Y")
                description: I18n.tr("The common case is a top anchor nudged down to clear the bar")
                unit: "px"
                minimum: 0
                maximum: 600
                value: row.pad.offsetY !== undefined ? row.pad.offsetY : 36
                onSliderDragFinished: newValue => row.changePad({
                        "offsetY": newValue
                    })
            }
        }

        // Niri has no per-pad entry animation setting; the page explains the unsupported control.
        SettingsDropdownRow {
            visible: ScratchpadService.fieldSupported("animation")
            text: I18n.tr("Entry animation")
            options: row.tabRoot ? row.tabRoot.animationOptions : []
            currentValue: row.tabRoot ? row.tabRoot.labelFor(row.tabRoot.animationOptions, row.tabRoot.animationValues, row.pad.animation || "slide-top", 0) : ""
            onValueChanged: value => {
                const index = row.tabRoot.animationOptions.indexOf(value);
                if (index >= 0)
                    row.changePad({
                        "animation": row.tabRoot.animationValues[index]
                    });
            }
        }


        Column {
            width: parent.width
            spacing: Theme.spacingXS

            StyledText {
                text: I18n.tr("Keybind")
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }

            VgsButton {
                text: row.capturing ? I18n.tr("Press a key combination…") : (row.pad.keybind || I18n.tr("Set keybind"))
                iconName: "keyboard"
                backgroundColor: row.capturing ? Theme.primary : Theme.surfaceContainerHigh
                textColor: row.capturing ? Theme.primaryText : Theme.surfaceText
                onClicked: row.requestCapture()

                focus: row.capturing
                Keys.onPressed: event => {
                    if (!row.capturing)
                        return;
                    event.accepted = true;
                    if (event.key === Qt.Key_Escape) {
                        row.captureFinished("");
                        return;
                    }
                    const combo = row.tabRoot ? row.tabRoot.keyEventToCombo(event) : "";
                    // A press that is only modifiers returns nothing: the user
                    // has not finished the chord yet, so keep listening.
                    if (combo)
                        row.captureFinished(combo);
                }
            }

            StyledText {
                width: parent.width
                visible: row.conflict.length > 0
                text: row.conflict
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.settingsFontSize
                color: Theme.error
            }
        }


        Column {
            width: parent.width
            spacing: Theme.spacingXS

            SettingsToggleRow {
                text: I18n.tr("Match class automatically")
                description: I18n.tr("Derived from the app. Turn this off only when the app maps with a class it does not declare.")
                checked: row.pad.classRegexAuto !== false
                onToggled: checked => {
                    if (!checked) {
                        row.autoNote = "";
                        row.changePad({
                            "classRegexAuto": false
                        });
                        return;
                    }
                    // Turning this on must actually re-derive. Persisting the
                    // flag alone would leave the manual pattern in force while
                    // the control claimed the opposite.
                    const derived = row.tabRoot ? row.tabRoot.autoClassRegexFor(row.pad.appId) : "";
                    if (derived) {
                        row.autoNote = "";
                        row.changePad({
                            "classRegexAuto": true,
                            "classRegex": derived
                        });
                        return;
                    }
                    // Without a desktop entry, automatic matching cannot replace the manual pattern.
                    row.autoNote = I18n.tr("Nothing to derive from: this scratchpad has no linked app, or the app is no longer installed. The pattern is unchanged.");
                }
            }

            StyledText {
                width: parent.width
                visible: row.autoNote.length > 0
                text: row.autoNote
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.settingsFontSize
                color: Theme.error
            }

            StyledText {
                width: parent.width
                text: row.pad.classRegex || ""
                wrapMode: Text.WrapAnywhere
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.settingsFontSize
                color: Theme.surfaceVariantText
            }

            VgsTextField {
                id: classField
                width: parent.width
                visible: row.pad.classRegexAuto === false
                text: row.pad.classRegex || ""
                placeholderText: "^(com\\.example\\.app)$"
                // Reject patterns that cannot compile; the helper would omit all rules for that pad.
                onEditingFinished: {
                    if (!text) {
                        row.regexNote = I18n.tr("A window class pattern is required.");
                        return;
                    }
                    try {
                        new RegExp(text);
                    } catch (e) {
                        row.regexNote = I18n.tr("Not a valid pattern: %1").arg(e.message || "");
                        return;
                    }
                    row.regexNote = "";
                    row.changePad({
                        "classRegex": text
                    });
                }
            }

            StyledText {
                width: parent.width
                visible: row.regexNote.length > 0
                text: row.regexNote
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.settingsFontSize
                color: Theme.error
            }

            VgsTextField {
                width: parent.width
                visible: row.pad.classRegexAuto === false
                text: row.pad.command || ""
                placeholderText: I18n.tr("Launch command")
                onEditingFinished: row.changePad({
                        "command": text
                    })
            }
        }

        SettingsToggleRow {
            text: I18n.tr("Preload at login")
            description: I18n.tr("Launch into the hidden workspace at startup so the first press is instant")
            checked: row.pad.preload === true
            onToggled: checked => row.changePad({
                    "preload": checked
                })
        }

        // ScratchpadService dismisses on focus loss using CompositorService as the shared focus owner.
        SettingsToggleRow {
            text: I18n.tr("Hide when focus leaves")
            description: I18n.tr("Dismiss the pad as soon as you focus another window")
            checked: row.pad.dismissOnFocusLoss === true
            onToggled: checked => row.changePad({
                    "dismissOnFocusLoss": checked
                })
        }
    }
}
