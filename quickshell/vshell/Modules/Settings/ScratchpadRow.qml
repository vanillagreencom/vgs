pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// One scratchpad: a compact summary row that expands in place into the full
// editor. Purely presentational — every change is emitted upward, so the tab
// keeps the single write path that regenerates the compositor config.
Column {
    id: row

    property var pad: ({})
    property int padIndex: 0
    property int padCount: 1
    property bool expanded: false
    property bool capturing: false
    property string conflict: ""
    // Set when automatic class matching was asked for but could not be honoured.
    property string autoNote: ""
    // Set when a manually typed class pattern was refused.
    property string regexNote: ""
    // The tab owns the option/value tables and the keybind normalization; this
    // component reads them rather than keeping a second copy that could drift.
    property var tabRoot: null

    signal toggleExpand
    signal requestCapture
    signal captureFinished(string combo)
    signal changePad(var changes)
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
                    // The class regex is what actually decides whether the pad
                    // works, so it belongs in the summary, not buried in the
                    // editor.
                    text: (row.pad.classRegex || "") + (row.pad.keybind ? "  ·  " + row.pad.keybind : "")
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.monoFontFamily
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    visible: row.conflict.length > 0
                    text: row.conflict
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
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
                    onClicked: row.remove()
                }

                VgsToggle {
                    checked: row.pad.enabled !== false
                    onToggled: checked => row.changePad({
                            "enabled": checked
                        })
                }
            }
        }
    }

    // --- editor ------------------------------------------------------------
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

        SettingsDropdownRow {
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

        // --- keybind -------------------------------------------------------
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
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }
        }

        // --- matching ------------------------------------------------------
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
                    // Nothing to derive from, so "automatic" would be a label
                    // with no mechanism behind it. Refuse and say why, rather
                    // than switching it on and quietly keeping the old pattern.
                    row.autoNote = I18n.tr("Nothing to derive from: this scratchpad has no linked app, or the app is no longer installed. The pattern is unchanged.");
                }
            }

            StyledText {
                width: parent.width
                visible: row.autoNote.length > 0
                text: row.autoNote
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }

            StyledText {
                width: parent.width
                text: row.pad.classRegex || ""
                wrapMode: Text.WrapAnywhere
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            VgsTextField {
                id: classField
                width: parent.width
                visible: row.pad.classRegexAuto === false
                text: row.pad.classRegex || ""
                placeholderText: "^(com\\.example\\.app)$"
                // Refuse the edit rather than persisting a pattern that cannot
                // compile. A rejected pad generates NO rules, so saving this
                // would silently stop the scratchpad working while the page
                // still showed it as configured.
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
                font.pixelSize: Theme.fontSizeSmall
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

        // There is deliberately NO "dismiss on focus loss" control here. The
        // field exists in the schema (see SettingsSpec.js) but nothing watches
        // focus yet, so the toggle would set a value that does nothing — the
        // same defect as a maintained-looking surface that is silently inert.
        // Do not add it back until a focus owner exists; adding a second
        // watcher for focus events is a one-owner-per-resource decision, not a
        // detail to settle inside this page.
    }
}
