import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

VgsModal {
    id: root

    layerNamespace: "vshell:capture"
    useOverlayLayer: true

    property int captureType: 0 // 0 screenshot, 1 recording
    property int selectedSourceIndex: 0
    property int delayIndex: 0
    property int outputIndex: 0
    property bool desktopAudio: true
    property bool microphone: false
    // Cursor is hidden by default for both capture types; unchecking the
    // "Hide cursor" toggle passes --cursor=true through to the capture scripts.
    property bool screenshotHideCursor: true
    property bool recordingHideCursor: true
    property var commandQueue: []

    property bool captureAvailable: true
    property bool recordingAvailable: true
    property bool ocrAvailable: true
    property bool captureEditAvailable: true
    property bool dependencyProbeFailed: false
    property var missingByFeature: ({})

    readonly property bool recordingActive: CaptureService.recordingActive
    readonly property string recordingSource: CaptureService.recordingSource

    readonly property var screenshotSources: [
        {
            mode: "region",
            icon: "crop_free",
            title: I18n.tr("Area"),
            description: I18n.tr("Drag a custom rectangle")
        },
        {
            mode: "window",
            icon: "select_window",
            title: I18n.tr("Window"),
            description: I18n.tr("Click a visible window")
        },
        {
            mode: "display",
            icon: "desktop_windows",
            title: I18n.tr("Display"),
            description: I18n.tr("Pick one monitor")
        },
        {
            mode: "all-displays",
            icon: "screenshot_monitor",
            title: I18n.tr("All displays"),
            description: I18n.tr("Capture the whole desktop")
        }
    ]
    readonly property var recordingSources: [
        {
            mode: "region",
            icon: "crop_free",
            title: I18n.tr("Area"),
            description: I18n.tr("Record a custom rectangle")
        },
        {
            mode: "window",
            icon: "select_window",
            title: I18n.tr("Window"),
            description: I18n.tr("Click a visible window")
        },
        {
            mode: "display",
            icon: "desktop_windows",
            title: I18n.tr("Display"),
            description: I18n.tr("Pick one monitor")
        }
    ]
    readonly property var sourceModel: captureType === 0 ? screenshotSources : recordingSources
    readonly property var delayValues: [0, 3, 5, 10]
    readonly property var outputValues: ["save-copy", "copy", "save", "edit"]
    readonly property bool currentFeatureAvailable: captureType === 0 ? captureAvailable : recordingAvailable

    modalWidth: Math.min(760, screenWidth - Theme.spacingXL * 2)
    modalHeight: Math.min(contentLoader && contentLoader.item ? contentLoader.item.implicitHeight : 480, screenHeight - Theme.spacingXL * 2)
    enableShadow: true
    onBackgroundClicked: close()

    function showOnScreen(screen) {
        targetScreen = screen || null;
        captureType = 0;
        selectedSourceIndex = 0;
        dependencyProcess.running = true;
        CaptureService.refreshRecording();
        open();
    }

    function show() {
        showOnScreen(null);
    }

    function toggleChooser() {
        if (shouldBeVisible)
            close();
        else
            show();
    }

    function selectCaptureType(index) {
        captureType = index;
        selectedSourceIndex = Math.min(selectedSourceIndex, sourceModel.length - 1);
    }

    function parseDependencies(text) {
        try {
            const features = JSON.parse(text).features || {};
            captureAvailable = features.capture?.available !== false;
            recordingAvailable = features.recording?.available !== false;
            ocrAvailable = features.ocr?.available !== false;
            captureEditAvailable = features["capture-edit"]?.available !== false;
            missingByFeature = {
                capture: features.capture?.missing || [],
                recording: features.recording?.missing || [],
                ocr: features.ocr?.missing || [],
                edit: features["capture-edit"]?.missing || []
            };
            dependencyProbeFailed = false;
            if (!captureEditAvailable && outputIndex === 3)
                outputIndex = 0;
        } catch (error) {
            dependencyProbeFailed = true;
        }
    }

    function missingText() {
        const key = captureType === 0 ? "capture" : "recording";
        const missing = missingByFeature[key] || [];
        return missing.length > 0 ? I18n.tr("Missing: %1").arg(missing.join(", ")) : I18n.tr("Capture tools are unavailable");
    }

    function queueCommand(args) {
        commandQueue = commandQueue.concat([[Paths.vshellCli].concat(args)]);
        close();
        if (!launchTimer.running)
            launchTimer.restart();
    }

    function runPrimaryAction() {
        if (captureType === 1 && recordingActive) {
            queueCommand(["capture", "screenrecording", "stop"]);
            return;
        }
        if (!currentFeatureAvailable || selectedSourceIndex < 0 || selectedSourceIndex >= sourceModel.length)
            return;

        const source = sourceModel[selectedSourceIndex].mode;
        if (captureType === 0) {
            if (outputIndex === 3 && !captureEditAvailable)
                return;
            queueCommand([
                "capture",
                "screenshot",
                source,
                outputValues[outputIndex],
                "--delay=" + delayValues[delayIndex],
                "--cursor=" + !screenshotHideCursor
            ]);
            return;
        }

        queueCommand([
            "capture",
            "screenrecording",
            "start",
            source,
            "--desktop-audio=" + desktopAudio,
            "--microphone=" + microphone,
            "--cursor=" + !recordingHideCursor
        ]);
    }

    function runOcr() {
        if (ocrAvailable)
            queueCommand(["capture", "text"]);
    }

    Process {
        id: dependencyProcess
        command: [Paths.vshellCli, "deps", "status", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.parseDependencies(text)
        }
    }

    Timer {
        id: launchTimer
        interval: root.animationDuration + 60
        repeat: false
        onTriggered: {
            if (root.commandQueue.length === 0)
                return;
            const remaining = root.commandQueue.slice();
            const command = remaining.shift();
            root.commandQueue = remaining;
            Quickshell.execDetached(command);
            if (root.commandQueue.length > 0)
                restart();
        }
    }

    onOpened: Qt.callLater(() => modalFocusScope.forceActiveFocus())
    onShouldHaveFocusChanged: {
        if (shouldHaveFocus)
            Qt.callLater(() => modalFocusScope.forceActiveFocus());
    }

    modalFocusScope.Keys.onPressed: event => {
        if (event.isAutoRepeat)
            return;

        switch (event.key) {
        case Qt.Key_Escape:
            close();
            event.accepted = true;
            break;
        case Qt.Key_Left:
            selectedSourceIndex = (selectedSourceIndex - 1 + sourceModel.length) % sourceModel.length;
            event.accepted = true;
            break;
        case Qt.Key_Right:
            selectedSourceIndex = (selectedSourceIndex + 1) % sourceModel.length;
            event.accepted = true;
            break;
        case Qt.Key_Up:
        case Qt.Key_Down:
            selectCaptureType(captureType === 0 ? 1 : 0);
            event.accepted = true;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            runPrimaryAction();
            event.accepted = true;
            break;
        case Qt.Key_S:
            selectCaptureType(0);
            event.accepted = true;
            break;
        case Qt.Key_R:
            selectCaptureType(1);
            event.accepted = true;
            break;
        case Qt.Key_T:
            runOcr();
            event.accepted = true;
            break;
        case Qt.Key_1:
        case Qt.Key_2:
        case Qt.Key_3:
        case Qt.Key_4:
            const index = event.key - Qt.Key_1;
            if (index < sourceModel.length)
                selectedSourceIndex = index;
            event.accepted = true;
            break;
        }
    }

    content: Component {
        Item {
            anchors.fill: parent
            // Size to content so modal padding remains even when the status row changes visibility.
            implicitHeight: contentColumn.implicitHeight + Theme.popoutPadding * 2

            Column {
                id: contentColumn
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.popoutPadding

                spacing: Theme.spacingXL

                Item {
                    width: parent.width
                    height: 36

                    StyledText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Capture")
                        font.pixelSize: Theme.fontSizeXLarge
                        font.weight: Theme.fontWeightSectionHeader
                        color: Theme.surfaceText
                    }

                    VgsActionButton {
                        id: closeButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "close"
                        tooltipText: I18n.tr("Close")
                        onClicked: root.close()
                    }
                }

                VgsButtonGroup {
                    width: parent.width
                    fillWidth: true
                    model: [I18n.tr("Screenshot"), I18n.tr("Screen recording")]
                    currentIndex: root.captureType
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            root.selectCaptureType(index);
                    }
                }

                Grid {
                    id: sourceGrid
                    width: parent.width
                    height: 118
                    columns: root.sourceModel.length
                    columnSpacing: Theme.spacingS

                    Repeater {
                        model: root.sourceModel

                        CaptureOptionCard {
                            required property var modelData
                            required property int index

                            width: (sourceGrid.width - sourceGrid.columnSpacing * (root.sourceModel.length - 1)) / root.sourceModel.length
                            height: sourceGrid.height
                            iconName: modelData.icon
                            title: modelData.title
                            description: modelData.description
                            selected: root.selectedSourceIndex === index
                            enabled: root.currentFeatureAvailable && !(root.captureType === 1 && root.recordingActive)
                            onClicked: root.selectedSourceIndex = index
                        }
                    }
                }


                Column {
                    id: screenshotOptions
                    width: parent.width
                    spacing: Theme.spacingM
                    visible: root.captureType === 0

                    Row {
                        width: parent.width
                        spacing: Theme.spacingL

                        Column {
                            width: (parent.width - parent.spacing) * 0.42
                            spacing: Theme.spacingS

                            StyledText {
                                text: I18n.tr("Delay")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceTextMedium
                            }

                            VgsButtonGroup {
                                width: parent.width
                                fillWidth: true
                                size: "small"
                                model: [I18n.tr("Off"), I18n.tr("3 sec"), I18n.tr("5 sec"), I18n.tr("10 sec")]
                                currentIndex: root.delayIndex
                                onSelectionChanged: (index, selected) => {
                                    if (selected)
                                        root.delayIndex = index;
                                }
                            }
                        }

                        Column {
                            width: parent.width - x
                            spacing: Theme.spacingS

                            StyledText {
                                text: I18n.tr("After capture")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceTextMedium
                            }

                            VgsButtonGroup {
                                width: parent.width
                                fillWidth: true
                                size: "small"
                                model: [I18n.tr("Save + copy"), I18n.tr("Copy"), I18n.tr("Save"), I18n.tr("Edit")]
                                currentIndex: root.outputIndex
                                onSelectionChanged: (index, selected) => {
                                    if (!selected)
                                        return;
                                    if (index === 3 && !root.captureEditAvailable) {
                                        ToastService.showWarning(I18n.tr("Screenshot editor unavailable"), root.missingByFeature.edit?.join(", ") || I18n.tr("Install satty to edit captures"));
                                        return;
                                    }
                                    root.outputIndex = index;
                                }
                            }
                        }
                    }

                    VgsToggle {
                        compact: true
                        text: I18n.tr("Hide cursor")
                        checked: root.screenshotHideCursor
                        horizontalPadding: 0
                        onToggled: checked => root.screenshotHideCursor = checked
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingXL
                    visible: root.captureType === 1

                    VgsToggle {
                        compact: true
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("System audio")
                        enabled: !root.recordingActive
                        checked: root.desktopAudio
                        horizontalPadding: 0
                        onToggled: checked => root.desktopAudio = checked
                    }

                    VgsToggle {
                        compact: true
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Microphone")
                        enabled: !root.recordingActive
                        checked: root.microphone
                        horizontalPadding: 0
                        onToggled: checked => root.microphone = checked
                    }

                    VgsToggle {
                        compact: true
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Hide cursor")
                        enabled: !root.recordingActive
                        checked: root.recordingHideCursor
                        horizontalPadding: 0
                        onToggled: checked => root.recordingHideCursor = checked
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 32
                    radius: Theme.controlRadius
                    color: root.recordingActive ? Theme.errorContainer : (root.dependencyProbeFailed ? Theme.warningContainer : Theme.surfaceContainerHigh)
                    visible: !root.currentFeatureAvailable || root.recordingActive || root.dependencyProbeFailed

                    StyledText {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        verticalAlignment: Text.AlignVCenter
                        text: root.recordingActive ? (root.recordingSource ? I18n.tr("Recording %1 — use the button below to stop").arg(root.recordingSource) : I18n.tr("A screen recording is active — use the button below to stop")) : (root.dependencyProbeFailed ? I18n.tr("Could not verify installed tools — capture will still try") : root.missingText())
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.recordingActive ? Theme.error : (root.dependencyProbeFailed ? Theme.warning : Theme.surfaceTextSecondary)
                        elide: Text.ElideRight
                    }
                }

                Item {
                    width: parent.width
                    height: 40

                    VgsButton {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Extract text")
                        iconName: "document_scanner"
                        variant: "secondary"
                        enabled: root.ocrAvailable
                        onClicked: root.runOcr()
                    }

                    VgsButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.captureType === 0 ? I18n.tr("Take screenshot") : (root.recordingActive ? I18n.tr("Stop recording") : I18n.tr("Start recording"))
                        iconName: root.captureType === 0 ? "photo_camera" : (root.recordingActive ? "stop_circle" : "screen_record")
                        enabled: root.currentFeatureAvailable || (root.captureType === 1 && root.recordingActive)
                        onClicked: root.runPrimaryAction()
                    }
                }

            }
        }
    }
}
