import QtQuick
import Quickshell
import qs.Common
import qs.Widgets

// Flatline segmented control (mac / shadcn style): a recessed track holding
// equal-width segments. The active segment reads as a quiet raised tile — not a
// loud accent pill — with full-strength text; inactive segments are muted text
// only. See docs/architecture/design-language.md.
Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    function checkParentDisablesTransparency() {
        let p = parent;
        while (p) {
            if (p.disablePopupTransparency === true)
                return true;
            p = p.parent;
        }
        return false;
    }

    property var model: []
    property int currentIndex: -1
    property string selectionMode: "single"
    property bool multiSelect: selectionMode === "multi"
    property var initialSelection: []
    property var currentSelection: initialSelection
    // Kept for API compatibility; the segmented control no longer draws a check
    // glyph (a Material-ism) — the raised tile signals selection.
    property bool checkEnabled: false
    property string size: "medium"
    property int buttonHeight: size === "small" ? 26 : 30
    property int minButtonWidth: size === "small" ? 52 : 60
    property int buttonPadding: size === "small" ? Theme.spacingM : Theme.spacingL
    property int checkIconSize: size === "small" ? Theme.iconSizeSmall - 2 : Theme.iconSizeSmall
    property int textSize: size === "small" ? Theme.fontSizeSmall : Theme.fontSizeMedium
    property bool userInteracted: false
    property bool usePopupTransparency: !checkParentDisablesTransparency()
    property real maximumWidth: -1
    property bool fillWidth: false
    // Retained for API compatibility (callers/aliases still set it); segments in
    // the unified track are contiguous, so it no longer inserts gaps.
    property int spacing: 0

    // Inner padding between the track edge and the segments.
    readonly property int trackPad: 3
    readonly property int segmentRadius: Math.max(4, Theme.controlRadius - 2)

    readonly property real _fillSegmentWidth: {
        const count = model?.length ?? 0;
        if (!fillWidth || count === 0 || width <= 0)
            return -1;
        return Math.max(minButtonWidth, (width - trackPad * 2) / count);
    }
    readonly property real _segmentCap: {
        const count = model?.length ?? 0;
        if (maximumWidth <= 0 || count === 0)
            return -1;
        return (maximumWidth - trackPad * 2) / count - 4;
    }

    signal selectionChanged(int index, bool selected)
    signal animationCompleted

    implicitHeight: buttonHeight + trackPad * 2
    implicitWidth: segmentRow.implicitWidth + trackPad * 2
    height: implicitHeight
    radius: Theme.controlRadius
    // Recessed track with a hairline border. Flatline is border-forward: the
    // border defines the control's bounds so it reads clearly as a segmented
    // toggle even when the track fill sits close to the surface behind it (dark
    // themes made a borderless track blend into the background). The active
    // segment is a lighter, crisply-bordered raised tile inside.
    color: usePopupTransparency ? Theme.withAlpha(Theme.surfaceContainerLow, Theme.popupTransparency) : Theme.surfaceContainerLow
    border.width: 1
    border.color: Theme.borderColor
    opacity: enabled ? 1 : 0.45

    Timer {
        id: animationTimer
        interval: Theme.shortDuration
        onTriggered: {
            root.userInteracted = false;
            root.animationCompleted();
        }
    }

    function isSelected(index) {
        if (multiSelect) {
            return repeater.itemAt(index)?.selected || false;
        }
        return index === currentIndex;
    }

    function selectItem(index) {
        userInteracted = true;
        if (multiSelect) {
            const modelValue = model[index];
            let newSelection = [...currentSelection];
            const isCurrentlySelected = newSelection.includes(modelValue);

            if (isCurrentlySelected) {
                newSelection = newSelection.filter(item => item !== modelValue);
            } else {
                newSelection.push(modelValue);
            }

            currentSelection = newSelection;
            selectionChanged(index, !isCurrentlySelected);
            animationTimer.restart();
        } else {
            const oldIndex = currentIndex;
            selectionChanged(index, true);
            if (oldIndex !== index && oldIndex >= 0) {
                selectionChanged(oldIndex, false);
            }
            animationTimer.restart();
        }
    }

    Row {
        id: segmentRow
        anchors.fill: parent
        anchors.margins: root.trackPad
        spacing: 0

        Repeater {
            id: repeater
            model: ScriptModel {
                values: root.model
            }

            delegate: Item {
                id: segment

                required property var modelData
                required property int index

                property bool selected: root.multiSelect ? root.currentSelection.includes(modelData) : (index === root.currentIndex)
                property bool hovered: mouseArea.containsMouse

                readonly property real contentNaturalWidth: buttonText.implicitWidth

                width: {
                    if (root._fillSegmentWidth > 0)
                        return root._fillSegmentWidth;
                    const natural = Math.max(contentNaturalWidth + root.buttonPadding * 2, root.minButtonWidth);
                    return root._segmentCap > 0 ? Math.min(natural, Math.max(root._segmentCap, root.minButtonWidth)) : natural;
                }
                height: root.buttonHeight

                // Raised tile for the active segment. The tile carries no border
                // of its own — the track border already bounds the control, and a
                // second border inside it read as clutter. Fill contrast against
                // the recessed track is what signals selection.
                Rectangle {
                    anchors.fill: parent
                    radius: root.segmentRadius
                    color: {
                        if (segment.selected)
                            return Theme.surfaceContainerHighest;
                        if (segment.hovered)
                            return Theme.surfaceHover;
                        return "transparent";
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shorterDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }

                StyledText {
                    id: buttonText
                    anchors.centerIn: parent
                    text: typeof segment.modelData === "string" ? segment.modelData : segment.modelData.text || ""
                    font.pixelSize: root.textSize
                    font.weight: segment.selected ? Font.DemiBold : Font.Medium
                    // Inactive segments stay clearly legible (medium-emphasis text),
                    // distinguished from the active one by weight + the raised tile
                    // rather than by being dimmed to near-invisible on dark themes.
                    color: segment.selected ? Theme.surfaceText : Theme.surfaceTextMedium
                    width: Math.min(implicitWidth, Math.max(0, segment.width - root.buttonPadding * 2))
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    maximumLineCount: 1

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shorterDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.enabled
                    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.selectItem(segment.index)
                }
            }
        }
    }
}
