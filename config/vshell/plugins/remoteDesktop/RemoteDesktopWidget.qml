import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Keep the host control visible while Sunshine is stopped so the user can
// start it. Distinguish listening from live capture in the pill.
PluginComponent {
    id: root

    property string pillMode: pluginData.pillMode || "status" // icon | status

    readonly property bool statusKnown: RemoteDesktopService.statusKnown
    readonly property bool installed: RemoteDesktopService.installed
    readonly property bool hostUp: RemoteDesktopService.running
    readonly property bool streaming: RemoteDesktopService.streaming
    readonly property bool sessionKnown: RemoteDesktopService.sessionKnown
    readonly property bool watchLive: RemoteDesktopService.watchLive
    readonly property bool busy: RemoteDesktopService.busy
    readonly property bool captureFallback: RemoteDesktopService.captureFallback
    // Unknown virtual-output state matters only on compositors where VGS manages it.
    readonly property bool outputUnknown: RemoteDesktopService.outputSupported && !RemoteDesktopService.outputKnown
    // Whether this compositor supports a VGS-managed virtual output.
    readonly property bool outputManaged: RemoteDesktopService.outputSupported

    // Keep this decision free of QML APIs: scripts/test-remote-desktop-state.js extracts the marked block and runs it as JavaScript.
    // Possible capture takes priority over uncertainty. Check statusKnown before
    // installed because the default false does not establish a missing host.
    // BEGIN STATE DECISION
    function visualStateFor(host) {
        // A lost session watch cannot establish that capture stopped. Keep the
        // live warning and identify the uncertainty separately.
        if (host.streaming)
            return host.sessionKnown ? "streaming" : "streaming-unconfirmed";
        if (!host.statusKnown)
            return "unknown";
        if (!host.installed)
            return "unavailable";
        if (!host.watchLive)
            return "stale";
        if (!host.running)
            return "off";
        // A running host with an unreadable session journal cannot establish idle state.
        return host.sessionKnown ? "listening" : "listening-unconfirmed";
    }
    // Return a Theme token name so tests can distinguish alarm and idle colors.
    function stateColorTokenFor(state) {
        switch (state) {
        case "streaming":
        case "streaming-unconfirmed":
            return "error";
        case "unknown":
        case "stale":
        case "listening-unconfirmed":
            return "warning";
        case "listening":
            return "primary";
        default:
            return "surfaceVariantText";
        }
    }

    // Use state color for alarm and uncertainty icons. Icon-only pills need
    // the same distinction as pills with text.
    function pillIconUsesStateColor(state) {
        const token = stateColorTokenFor(state);
        return token === "error" || token === "warning";
    }

    // Return a translation key and parameters. QML renders the descriptor so
    // I18n can translate it and this extractable decision stays free of QML APIs.
    // The caller supplies fallback reason text and composes session detail.
    function tooltipFor(state, facts) {
        switch (state) {
        case "streaming":
            // Host status can be uncertain while a live session is confirmed.
            return {
                "key": facts.statusKnown ? "streaming" : "streaming-host-uncertain",
                "reason": "",
                "detail": facts.sessionDetail || ""
            };
        case "streaming-unconfirmed":
            return { "key": "streaming-unconfirmed", "reason": facts.sessionError || "", "detail": "" };
        case "unknown":
            return { "key": "unknown", "reason": facts.statusError || "", "detail": "" };
        case "unavailable":
            return { "key": "unavailable", "reason": facts.unavailableReason || "", "detail": "" };
        case "stale":
            return { "key": "stale", "reason": facts.watchError || "", "detail": "" };
        case "listening-unconfirmed":
            return { "key": "listening-unconfirmed", "reason": facts.sessionError || "", "detail": "" };
        case "listening":
            // Report known capture fallback before an unchecked virtual-output state.
            if (facts.captureFallback)
                return { "key": "listening-capture-fallback", "reason": "", "detail": "" };
            if (facts.outputUnknown)
                return { "key": "listening-output-unknown", "reason": "", "detail": "" };
            return { "key": "listening", "reason": "", "detail": "" };
        default:
            return { "key": "off", "reason": "", "detail": "" };
        }
    }

    // Compose available session details: codec, bitrate, and depth.
    function sessionDetailFrom(facts) {
        const parts = [];
        if (facts.codec)
            parts.push(facts.codec);
        if (facts.bitrateBps > 0)
            parts.push(Math.round(facts.bitrateBps / 1000) + " kbps");
        if (facts.colorDepth)
            parts.push(facts.colorDepth);
        return parts.join(" · ");
    }

    // Choose a host subtitle, including real-monitor capture on compositors
    // where VGS cannot manage a virtual output.
    function upSubtitleFor(facts) {
        if (facts.outputUnknown)
            return { "key": "output-unknown", "output": facts.outputName };
        if (facts.outputPresent)
            return { "key": "output-present", "output": facts.outputName };
        if (facts.outputManaged)
            // A missing managed output means the host can capture a real monitor.
            return { "key": "output-missing", "output": facts.outputName };
        return { "key": "output-unmanaged", "compositor": facts.compositor || "" };
    }
    // END STATE DECISION

    readonly property string visualState: root.visualStateFor({
        "streaming": root.streaming,
        "sessionKnown": root.sessionKnown,
        "statusKnown": root.statusKnown,
        "installed": root.installed,
        "watchLive": root.watchLive,
        "running": root.hostUp
    })

    readonly property string stateIcon: {
        switch (root.visualState) {
        case "streaming":
        case "streaming-unconfirmed":
            return "cast_connected";
        case "unknown":
        case "stale":
            return "sync_problem";
        default:
            return "cast";
        }
    }

    // Keep possible capture in the alarm color when confirmation is unavailable.
    readonly property color stateColor: {
        switch (root.stateColorTokenFor(root.visualState)) {
        case "error":
            return Theme.error;
        case "warning":
            return Theme.warning;
        case "primary":
            return Theme.primary;
        default:
            return Theme.surfaceVariantText;
        }
    }

    readonly property color pillIconColor: root.pillIconUsesStateColor(root.visualState) ? root.stateColor : Theme.widgetIconColor

    readonly property string stateText: {
        switch (root.visualState) {
        case "unavailable":
            return "";
        case "unknown":
        case "stale":
            return "?";
        case "streaming":
            return "LIVE";
        case "streaming-unconfirmed":
            return "LIVE?";
        case "listening":
            return "On";
        case "listening-unconfirmed":
            return "On?";
        default:
            return "Off";
        }
    }

    // Translate the descriptor selected by tooltipFor.
    function tooltipText() {
        const t = root.tooltipFor(root.visualState, {
            "statusKnown": root.statusKnown,
            "sessionDetail": root.sessionDetail(),
            "sessionError": RemoteDesktopService.sessionError,
            "statusError": RemoteDesktopService.statusError,
            "unavailableReason": RemoteDesktopService.unavailableReason,
            "watchError": RemoteDesktopService.watchError,
            "captureFallback": root.captureFallback,
            "outputUnknown": root.outputUnknown
        });
        const output = RemoteDesktopService.outputName;
        switch (t.key) {
        case "streaming":
            return "Someone is streaming this machine" + (t.detail ? " — " + t.detail : "");
        case "streaming-host-uncertain":
            return "Someone is streaming this machine (host state uncertain)" + (t.detail ? " — " + t.detail : "");
        case "streaming-unconfirmed":
            return "Someone may still be streaming this machine — " + (t.reason || "nothing is confirming the session right now");
        case "unknown":
            return "Remote desktop state is unknown — " + (t.reason || "the host status check has not answered yet");
        case "unavailable":
            return "Remote desktop unavailable — " + (t.reason || "Sunshine is not installed");
        case "stale":
            return "Remote desktop state may be out of date — " + (t.reason || "the host event watch is not running");
        case "listening-unconfirmed":
            return "Remote desktop is up — whether anyone is connected could not be checked: " + (t.reason || "the host journal could not be read");
        case "listening-capture-fallback":
            return "Remote desktop is up, but capturing a real monitor — " + output + " is missing";
        case "listening-output-unknown":
            return "Remote desktop is up — whether it is capturing " + output + " could not be checked";
        case "listening":
            return "Remote desktop is up, nobody connected";
        default:
            return "Remote desktop is off — click to open, toggle inside to start";
        }
    }

    function sessionDetail() {
        return root.sessionDetailFrom({
            "codec": RemoteDesktopService.sessionCodec,
            "bitrateBps": RemoteDesktopService.sessionBitrateBps,
            "colorDepth": RemoteDesktopService.sessionColorDepth
        });
    }

    // Translate the descriptor selected by upSubtitleFor.
    function upSubtitleText() {
        const s = root.upSubtitleFor({
            "outputUnknown": root.outputUnknown,
            "outputPresent": RemoteDesktopService.outputPresent,
            "outputManaged": root.outputManaged,
            "outputName": RemoteDesktopService.outputName,
            "compositor": RemoteDesktopService.compositor
        });
        switch (s.key) {
        case "output-unknown":
            return "capture target could not be checked";
        case "output-present":
            return "capturing " + s.output;
        case "output-missing":
            return "capturing a real monitor — " + s.output + " is missing";
        default:
            return s.compositor && s.compositor !== "unknown"
                ? "capturing an existing monitor — no virtual output is managed on " + s.compositor
                : "capturing an existing monitor — no virtual output is managed here";
        }
    }

    Ref {
        service: RemoteDesktopService
    }

    // Starting a host opens a listening port and can create a virtual output.
    // Require an explicit control activation; hover only opens the popout.
    pillClickOnHover: false

    property var _hoverItem: null

    VgsTooltip {
        id: sharedTip
        targetScreen: root.parentScreen
    }

    Timer {
        id: tipDelay
        interval: 250
        repeat: false
        onTriggered: root._doShowTip()
    }

    function _requestTip(item) {
        root._hoverItem = item;
        tipDelay.restart();
    }

    function _cancelTip() {
        tipDelay.stop();
        sharedTip.hide();
        root._hoverItem = null;
    }

    function _doShowTip() {
        const item = root._hoverItem;
        if (!item)
            return;
        const edge = root.axis?.edge || "top";
        const pos = item.mapToItem(null, 0, 0);
        const gap = Theme.spacingS;
        if (edge === "left" || edge === "right") {
            const isLeft = edge === "left";
            const screenW = root.parentScreen?.width ?? 0;
            const x = isLeft ? (root.barThickness + gap) : (screenW - root.barThickness - gap);
            sharedTip.show(root.tooltipText(), x, pos.y + item.height / 2, root.parentScreen, isLeft, !isLeft);
        } else {
            const isBottom = edge === "bottom";
            const screenH = root.parentScreen?.height ?? 0;
            const y = isBottom ? (screenH - root.barThickness - gap - 32) : (root.barThickness + gap);
            sharedTip.show(root.tooltipText(), pos.x + item.width / 2, y, root.parentScreen, false, false);
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                id: pillIcon
                name: root.stateIcon
                size: root.iconSize
                color: root.pillIconColor
                filled: root.visualState === "streaming"
                opacity: root.installed ? 1 : 0.4
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.stateText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.stateColor
                anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(pillIcon)
                onExited: root._cancelTip()
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                id: pillIconV
                name: root.stateIcon
                size: root.iconSize
                color: root.pillIconColor
                filled: root.visualState === "streaming"
                opacity: root.installed ? 1 : 0.4
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.stateText
                font.pixelSize: Theme.fontSizeSmall
                color: root.stateColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(pillIconV)
                onExited: root._cancelTip()
            }
        }
    }

    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Remote Desktop"
            detailsText: {
                if (root.streaming)
                    return root.sessionKnown ? "Streaming now" : "Streaming — unconfirmed";
                if (!root.statusKnown)
                    return "State unknown";
                if (!root.installed)
                    return "Not installed";
                if (!root.hostUp)
                    return "Off";
                return root.sessionKnown ? "Listening" : "Listening — sessions unconfirmed";
            }
            showCloseButton: true

            // Bar -> Widgets, where a bundled plugin's settings live.
            configurable: true
            onSettingsRequested: PopoutService.openSettingsWithTab("bar_widgets")

            Column {
                width: parent.width
                spacing: Theme.spacingS

                StyledRect {
                    width: parent.width
                    height: hostRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    RowLayout {
                        id: hostRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: root.stateIcon
                            size: Theme.iconSize
                            color: root.stateColor
                            filled: root.visualState === "streaming"
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Column {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 1

                            StyledText {
                                text: {
                                    if (root.streaming)
                                        return root.sessionKnown ? "Somebody is streaming this machine" : "Somebody may still be streaming this machine";
                                    if (root.busy)
                                        return root.hostUp ? "Stopping…" : "Starting…";
                                    if (!root.statusKnown)
                                        return "Host state is unknown";
                                    if (!root.installed)
                                        return "Sunshine is not installed";
                                    if (!root.hostUp)
                                        return "Host is off";
                                    return root.sessionKnown ? "Host is up, nobody connected" : "Host is up, sessions unconfirmed";
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: root.streaming ? Theme.error : Theme.surfaceText
                            }

                            StyledText {
                                visible: text.length > 0
                                width: parent.width
                                text: {
                                    if (root.streaming)
                                        return root.sessionKnown ? root.sessionDetail() : "nothing is confirming this session right now";
                                    if (!root.statusKnown)
                                        return RemoteDesktopService.statusError || "waiting for the first answer";
                                    if (!root.installed)
                                        return RemoteDesktopService.unavailableReason;
                                    if (root.hostUp)
                                        return root.upSubtitleText();
                                    return "starts on demand — nothing listens until you turn it on";
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }

                        VgsToggle {
                            Layout.alignment: Qt.AlignVCenter
                            hideText: true
                            checked: root.hostUp
                            // Unknown host state cannot supply a reliable toggle position.
                            enabled: root.statusKnown && root.installed && !root.busy
                            onToggled: want => {
                                if (want)
                                    RemoteDesktopService.start();
                                else
                                    RemoteDesktopService.stop();
                            }
                        }
                    }
                }

                // Warn when the host can capture a real monitor instead of its managed output.
                StyledRect {
                    width: parent.width
                    visible: root.captureFallback
                    height: fallbackRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    RowLayout {
                        id: fallbackRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: "warning"
                            size: Theme.iconSize
                            color: Theme.error
                            Layout.alignment: Qt.AlignTop
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: RemoteDesktopService.outputName + " is missing, so the host is capturing a real monitor — your own screen, not the virtual one. Stop and start it again to recreate the output."
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }
                    }
                }

                StyledRect {
                    width: parent.width
                    visible: !root.statusKnown || root.visualState === "stale" || (root.hostUp && !root.sessionKnown) || root.outputUnknown
                    height: staleRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    RowLayout {
                        id: staleRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: "sync_problem"
                            size: Theme.iconSize
                            color: Theme.warning
                            Layout.alignment: Qt.AlignTop
                        }

                        Column {
                            Layout.fillWidth: true
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: root.statusKnown ? "Live updates are not running" : "This state has not been confirmed"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                width: parent.width
                                text: {
                                    const reason = RemoteDesktopService.statusError || RemoteDesktopService.watchError || RemoteDesktopService.sessionError || "the host event watch is not running";
                                    if (!root.statusKnown || !root.sessionKnown)
                                        return reason + ". Whether anyone is connected cannot be confirmed right now.";
                                    if (root.outputUnknown)
                                        return "Whether the host is capturing " + RemoteDesktopService.outputName + " or a real monitor could not be checked.";
                                    return reason + ". What is shown here may be out of date.";
                                }
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    // Show session details only after confirmation; a lost watch clears cached fields.
                    visible: root.streaming && root.sessionKnown

                    StyledText {
                        text: "Session"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: [
                            // A connected event can precede the authoritative client count. Do not
                            // render a default zero as a confirmed count.
                            { label: "Clients", value: RemoteDesktopService.sessionCountKnown ? String(RemoteDesktopService.sessionCount) : "confirming…" },
                            { label: "Codec", value: RemoteDesktopService.sessionCodec },
                            { label: "Bitrate", value: RemoteDesktopService.sessionBitrateBps > 0 ? (Math.round(RemoteDesktopService.sessionBitrateBps / 1000) + " kbps") : "" },
                            { label: "Colour depth", value: RemoteDesktopService.sessionColorDepth },
                            { label: "Since", value: RemoteDesktopService.sessionSince.replace("T", " ") }
                        ]

                        delegate: RowLayout {
                            required property var modelData
                            width: parent.width
                            visible: modelData.value.length > 0
                            spacing: Theme.spacingS

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                            StyledText {
                                text: modelData.value
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }
                        }
                    }
                }

                VgsButton {
                    width: parent.width
                    visible: root.installed
                    text: "Open the web UI"
                    iconName: "open_in_new"
                    variant: "secondary"
                    onClicked: RemoteDesktopService.openWebUi()
                }

                StyledText {
                    width: parent.width
                    visible: root.installed && RemoteDesktopService.webUi.length > 0
                    text: RemoteDesktopService.webUi
                    font.pixelSize: Theme.fontSizeSmall
                    isMonospace: true
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }

                // Sunshine does not identify the paired client owning a journal session.
                // List paired devices without claiming that they are connected.
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: RemoteDesktopService.pairedClients.length > 0 || !RemoteDesktopService.pairedClientsKnown || RemoteDesktopService.pairedClientsUndecodable > 0

                    StyledText {
                        text: "Paired devices"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width
                        visible: !RemoteDesktopService.pairedClientsKnown
                        text: RemoteDesktopService.pairedClientsError || "The paired device list could not be read."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                    }

                    Repeater {
                        model: RemoteDesktopService.pairedClientsKnown ? RemoteDesktopService.pairedClients : []

                        delegate: RowLayout {
                            required property var modelData
                            width: parent.width
                            spacing: Theme.spacingS

                            VgsIcon {
                                name: "devices"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: modelData
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: RemoteDesktopService.pairedClientsKnown && RemoteDesktopService.pairedClientsUndecodable > 0
                        text: RemoteDesktopService.pairedClientsUndecodable + " device name(s) are not valid UTF-8 and are not shown."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                    }

                    StyledText {
                        width: parent.width
                        visible: RemoteDesktopService.pairedClientsKnown
                        text: "Devices allowed to connect. Which one is connected is not something the host reports."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }
    }
}
