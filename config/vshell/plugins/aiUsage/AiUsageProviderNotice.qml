import QtQuick
import qs.Common
import qs.Widgets

// What one provider has to say when it contributes no account cards: it has
// not been set up, every one of its accounts is hidden, or it has not answered
// yet. Each is a different state and only one of them is a fault, so a
// provider that is merely unconfigured never reads as a broken one.
Item {
    id: notice

    // The AiUsageWidget root.
    property var host: null
    // One entry from view.sections.
    property var sectionData: null

    signal setupRequested

    readonly property bool needsSetup: !!notice.sectionData && !notice.sectionData.configured
    readonly property bool waiting: !!notice.sectionData && notice.sectionData.pending
        && notice.sectionData.configured
    readonly property bool everythingHidden: !!notice.sectionData
        && notice.sectionData.configured && notice.sectionData.total > 0
        && notice.sectionData.shown === 0

    visible: notice.needsSetup || notice.waiting || notice.everythingHidden
    height: visible ? body.implicitHeight + Theme.spacingM * 2 : 0

    StyledRect {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        visible: notice.visible

        Column {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                text: {
                    if (notice.needsSetup)
                        return notice.sectionData.setupHint;
                    if (notice.waiting)
                        return "Checking usage…";
                    return notice.host
                        ? notice.host.accountCountLabel(notice.sectionData.total) + " hidden"
                        : "";
                }
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            VgsButton {
                visible: notice.needsSetup
                text: "Set up"
                iconName: "key"
                backgroundColor: Theme.surfaceContainerHighest
                textColor: Theme.surfaceText
                buttonHeight: 30
                onClicked: notice.setupRequested()
            }
        }
    }
}
