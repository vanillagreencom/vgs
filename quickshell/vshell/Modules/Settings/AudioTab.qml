import QtQuick
import Quickshell.Services.Pipewire
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import qs.Modals.Common

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property var outputDevices: []
    property var inputDevices: []
    function promptRenameDevice(device) {
        const original = AudioService.hasDeviceAlias(device.name)
            ? I18n.tr("Original: %1").arg(AudioService.originalName(device)) + "\n"
            : "";
        renameDeviceModal.showWithOptions({
            title: I18n.tr("Set Custom Device Name"),
            message: original + device.name,
            placeholder: I18n.tr("Enter device name..."),
            initialText: AudioService.displayName(device),
            confirmText: I18n.tr("Save"),
            onConfirm: text => {
                if (text.trim() !== "")
                    AudioService.setDeviceAlias(device.name, text);
            }
        });
    }
    property bool isReloadingAudio: false
    property var hiddenOutputDeviceNames: SessionData.hiddenOutputDeviceNames ?? []
    property var hiddenInputDeviceNames: SessionData.hiddenInputDeviceNames ?? []
    property bool showHiddenOutputDevices: false
    property bool showHiddenInputDevices: false

    function persistHiddenOutputDeviceNames(deviceNames) {
        const uniqueNames = [...new Set(deviceNames)];
        hiddenOutputDeviceNames = uniqueNames;
        SessionData.setHiddenOutputDeviceNames(uniqueNames);
    }

    function persistHiddenInputDeviceNames(deviceNames) {
        const uniqueNames = [...new Set(deviceNames)];
        hiddenInputDeviceNames = uniqueNames;
        SessionData.setHiddenInputDeviceNames(uniqueNames);
    }

    function updateDeviceList() {
        const allNodes = Pipewire.nodes.values;


        const sortDevices = (a, b) => {
            if (a === AudioService.sink && b !== AudioService.sink)
                return -1;
            if (b === AudioService.sink && a !== AudioService.sink)
                return 1;
            const nameA = AudioService.displayName(a).toLowerCase();
            const nameB = AudioService.displayName(b).toLowerCase();
            return nameA.localeCompare(nameB);
        };

        const outputs = allNodes.filter(node => {
            return node.audio && node.isSink && !node.isStream;
        });
        outputDevices = outputs.sort(sortDevices);

        const inputs = allNodes.filter(node => {
            return node.audio && !node.isSink && !node.isStream;
        });

        const sortInputs = (a, b) => {
            if (a === AudioService.source && b !== AudioService.source)
                return -1;
            if (b === AudioService.source && a !== AudioService.source)
                return 1;
            const nameA = AudioService.displayName(a).toLowerCase();
            const nameB = AudioService.displayName(b).toLowerCase();
            return nameA.localeCompare(nameB);
        };

        inputDevices = inputs.sort(sortInputs);
    }

    Component.onCompleted: {
        hiddenOutputDeviceNames = SessionData.hiddenOutputDeviceNames ?? [];
        hiddenInputDeviceNames = SessionData.hiddenInputDeviceNames ?? [];
        updateDeviceList();
    }

    Connections {
        target: Pipewire.nodes
        function onValuesChanged() {
            root.updateDeviceList();
        }
    }

    Connections {
        target: AudioService
        function onWireplumberReloadStarted() {
            root.isReloadingAudio = true;
        }
        function onWireplumberReloadCompleted(success) {
            Qt.callLater(() => {
                delayTimer.start();
            });
        }
        function onDeviceAliasChanged(nodeName, newAlias) {
            root.updateDeviceList();
        }
    }

    Timer {
        id: delayTimer
        interval: 2000
        repeat: false
        onTriggered: {
            root.isReloadingAudio = false;
            root.updateDeviceList();
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                tab: "audio"
                tags: ["audio", "device", "output", "speaker", "headphone", "rename", "volume", "hide"]
                title: I18n.tr("Output Devices", "Audio settings: speaker/headphone devices")
                settingKey: "audioOutputDevices"
                iconName: "volume_up"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Rename or hide output devices and set a per-device volume limit", "Audio settings description")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignLeft
                    }

                    SettingsDivider {}

                    Repeater {
                        model: root.outputDevices.filter(d => !root.hiddenOutputDeviceNames.includes(d.name))

                        delegate: Column {
                            required property var modelData
                            width: parent?.width ?? 0
                            spacing: 0

                            DeviceAliasRow {
                                deviceNode: modelData
                                deviceType: "output"
                                showHideButton: true

                                onEditRequested: device => root.promptRenameDevice(device)

                                onResetRequested: device => {
                                    AudioService.removeDeviceAlias(device.name);
                                }

                                onHideRequested: device => {
                                    root.persistHiddenOutputDeviceNames([...root.hiddenOutputDeviceNames, device.name]);
                                }
                            }

                            Item {
                                width: parent.width
                                height: 36

                                StyledText {
                                    id: maxVolLabel
                                    text: I18n.tr("Max Volume", "Audio settings: maximum volume limit per device") + " · " + maxVolSlider.value + "%"
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM + Theme.iconSize + Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignLeft
                                }

                                VgsSlider {
                                    id: maxVolSlider
                                    anchors.left: maxVolLabel.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 36
                                    minimum: 100
                                    maximum: 200
                                    step: 5
                                    showValue: true
                                    wheelEnabled: false
                                    centerMinimum: true
                                    unit: "%"
                                    onSliderValueChanged: newValue => {
                                        SessionData.setDeviceMaxVolume(modelData.name, newValue);
                                    }
                                }

                                Binding {
                                    target: maxVolSlider
                                    property: "value"
                                    value: SessionData.deviceMaxVolumes[modelData.name] ?? 100
                                    when: !maxVolSlider.isDragging
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("No output devices found", "Audio settings empty state")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        visible: root.outputDevices.filter(d => !root.hiddenOutputDeviceNames.includes(d.name)).length === 0 && root.hiddenOutputDeviceNames.length === 0
                        topPadding: Theme.spacingM
                    }

                    Column {
                        width: parent.width
                        spacing: 0
                        visible: root.hiddenOutputDeviceNames.length > 0

                        SettingsDivider {}

                        Item {
                            width: parent.width
                            height: 36

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                VgsIcon {
                                    name: "visibility_off"
                                    size: Theme.iconSize - 4
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Hidden (%1)", "count of hidden audio devices").arg(root.hiddenOutputDeviceNames.length)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            VgsIcon {
                                name: root.showHiddenOutputDevices ? "expand_less" : "expand_more"
                                size: Theme.iconSize - 4
                                color: Theme.surfaceVariantText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showHiddenOutputDevices = !root.showHiddenOutputDevices
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: 0
                            visible: root.showHiddenOutputDevices

                            Repeater {
                                model: root.outputDevices.filter(d => root.hiddenOutputDeviceNames.includes(d.name))

                                delegate: DeviceAliasRow {
                                    required property var modelData
                                    deviceNode: modelData
                                    deviceType: "output"
                                    isHidden: true
                                    showHideButton: true

                                    onHideRequested: device => {
                                        root.persistHiddenOutputDeviceNames(root.hiddenOutputDeviceNames.filter(n => n !== device.name));
                                    }

                                    onResetRequested: device => {
                                        AudioService.removeDeviceAlias(device.name);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                tab: "audio"
                tags: ["audio", "device", "input", "microphone", "mic", "rename", "hide"]
                title: I18n.tr("Input Devices")
                settingKey: "audioInputDevices"
                iconName: "mic"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Rename or hide input devices", "Audio settings description")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignLeft
                    }

                    SettingsDivider {}

                    Repeater {
                        model: root.inputDevices.filter(d => !root.hiddenInputDeviceNames.includes(d.name))

                        delegate: DeviceAliasRow {
                            required property var modelData

                            deviceNode: modelData
                            deviceType: "input"
                            showHideButton: true

                            onEditRequested: device => root.promptRenameDevice(device)

                            onResetRequested: device => {
                                AudioService.removeDeviceAlias(device.name);
                            }

                            onHideRequested: device => {
                                root.persistHiddenInputDeviceNames([...root.hiddenInputDeviceNames, device.name]);
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("No input devices found", "Audio settings empty state")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        visible: root.inputDevices.filter(d => !root.hiddenInputDeviceNames.includes(d.name)).length === 0 && root.hiddenInputDeviceNames.length === 0
                        topPadding: Theme.spacingM
                    }

                    Column {
                        width: parent.width
                        spacing: 0
                        visible: root.hiddenInputDeviceNames.length > 0

                        SettingsDivider {}

                        Item {
                            width: parent.width
                            height: 36

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                VgsIcon {
                                    name: "visibility_off"
                                    size: Theme.iconSize - 4
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Hidden (%1)", "count of hidden audio devices").arg(root.hiddenInputDeviceNames.length)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            VgsIcon {
                                name: root.showHiddenInputDevices ? "expand_less" : "expand_more"
                                size: Theme.iconSize - 4
                                color: Theme.surfaceVariantText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showHiddenInputDevices = !root.showHiddenInputDevices
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: 0
                            visible: root.showHiddenInputDevices

                            Repeater {
                                model: root.inputDevices.filter(d => root.hiddenInputDeviceNames.includes(d.name))

                                delegate: DeviceAliasRow {
                                    required property var modelData
                                    deviceNode: modelData
                                    deviceType: "input"
                                    isHidden: true
                                    showHideButton: true

                                    onHideRequested: device => {
                                        root.persistHiddenInputDeviceNames(root.hiddenInputDeviceNames.filter(n => n !== device.name));
                                    }

                                    onResetRequested: device => {
                                        AudioService.removeDeviceAlias(device.name);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        id: loadingOverlay
        anchors.fill: parent
        color: Theme.withAlpha(Theme.surface, 0.9)
        visible: root.isReloadingAudio
        z: 100

        Column {
            anchors.centerIn: parent
            spacing: Theme.spacingL

            Rectangle {
                width: 80
                height: 80
                radius: 40
                color: Theme.primaryContainer
                anchors.horizontalCenter: parent.horizontalCenter

                VgsIcon {
                    id: spinningIcon
                    name: "refresh"
                    size: 40
                    color: Theme.primary
                    anchors.centerIn: parent
                    smoothTransform: loadingOverlay.visible

                    RotationAnimator {
                        target: spinningIcon
                        from: 0
                        to: 360
                        duration: 1500
                        loops: Animation.Infinite
                        running: loadingOverlay.visible
                    }
                }
            }

            Column {
                spacing: Theme.spacingS
                anchors.horizontalCenter: parent.horizontalCenter

                StyledText {
                    text: I18n.tr("Restarting audio system...", "Loading overlay while WirePlumber restarts")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: I18n.tr("This may take a few seconds", "Loading overlay subtitle")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    InputModal {
        id: renameDeviceModal
    }
}
