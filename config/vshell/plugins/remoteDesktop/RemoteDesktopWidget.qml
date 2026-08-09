import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Sunshine remote-desktop host, in the bar.
//
// The pill is ALWAYS present, dimmed when Sunshine is not installed — the same
// shape as sudoToggle. Hiding it while the host is down would remove the only
// thing the widget is for: this host is deliberately not autostarted, so
// "stopped" is its normal state and starting it is the whole affordance. A
// control that appears only once you have already started the thing by other
// means is not a control.
//
// Three states, never two. "Listening" and "somebody is watching my screen" are
// different facts, and an unnoticed live capture is a privacy problem, so the
// streaming state borrows the capture language already established by
// `screenRecord`: Theme.error, filled glyph, a word rather than an icon alone.
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
    // The third knowledge axis: hyprctl could not be asked whether the virtual
    // output exists. Only meaningful where VGS manages one at all.
    readonly property bool outputUnknown: RemoteDesktopService.outputSupported && !RemoteDesktopService.outputKnown

    // "streaming"   -> a client is connected right now.
    // "unknown"     -> no usable answer yet, or the last probe could not run.
    // "unavailable" -> Sunshine is not installed here.
    // "stale"       -> the event watch is down, so nothing below is trustworthy.
    // "listening"   -> the host is up and nobody is connected.
    // "off"         -> the host is down.
    //
    // ORDER MATTERS, twice over.
    //
    // `streaming` is tested FIRST, ahead of every uncertainty state. A capture
    // that may still be live must fail loud: downgrading it to a question mark
    // because a probe failed would hide the one thing this widget exists to
    // show. Uncertainty is reported alongside it in the popout instead.
    //
    // `statusKnown` is tested before `installed`, because `installed` defaults
    // to false — testing it first rendered "Sunshine is not installed" for
    // every instant before the first reply, and again after any failed probe.
    // A default is not an answer.
    // Pure decision function. `scripts/test-remote-desktop-state.js` extracts
    // THIS source text and exercises it directly, so the shipped ordering is
    // what is tested — bundled plugins get no runtime coverage from
    // `qml-smoke.sh --nested` (VGS-19), and both bugs this closes were ordering
    // bugs. Keep it free of QML API calls.
    // BEGIN STATE DECISION
    function visualStateFor(host) {
        // A possible capture outranks everything, but "confirmed live" and
        // "last we heard, live" are not the same claim. Losing the event watch
        // makes the session unknown, not idle, so it renders as its own state:
        // still red, still says LIVE, with the uncertainty explicit. Showing a
        // plain LIVE on a dead watcher's last message would claim certainty
        // nothing has; showing idle would hide a capture that may be running.
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
        // Host up, watch alive, but the journal could not be read: "On" would
        // claim nobody is watching, which is the same overstatement as a plain
        // LIVE on an unconfirmed session — just in the reassuring direction,
        // which is the worse one to get wrong.
        return host.sessionKnown ? "listening" : "listening-unconfirmed";
    }
    // Which colour token a state carries. Returned as a NAME, not a Theme
    // value, so the state table can be asserted without a Theme instance —
    // "streaming must not look like listening" is a claim about these tokens.
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

    // Whether the BAR PILL's glyph takes the state colour instead of the bar's
    // uniform widget icon colour.
    //
    // Bars keep one icon colour by convention, and for "off" and "listening"
    // that convention is right — nothing is wrong, and a bar of differently
    // coloured glyphs is noise. It is wrong for the states that mean something
    // is happening or unknown: in `icon` pill mode there is no text at all, so
    // `cast_connected` vs `cast` was the ONLY difference between "someone is
    // watching my screen" and "idle". A glyph shape is not enough signal for
    // that, which is the whole point of the streaming/listening split.
    function pillIconUsesStateColor(state) {
        const token = stateColorTokenFor(state);
        return token === "error" || token === "warning";
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

    // Unconfirmed keeps the alarm colour: softening it would trade a possible
    // live capture for a tidier bar.
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

    function tooltipText() {
        // Mirrors visualState's ordering, for the same two reasons.
        if (root.streaming) {
            if (!root.sessionKnown)
                return "Someone may still be streaming this machine — " + (RemoteDesktopService.sessionError || "nothing is confirming the session right now");
            const detail = root.sessionDetail();
            const uncertain = root.statusKnown ? "" : " (host state uncertain)";
            return "Someone is streaming this machine" + uncertain + (detail ? " — " + detail : "");
        }
        if (!root.statusKnown)
            return "Remote desktop state is unknown — " + (RemoteDesktopService.statusError || "the host status check has not answered yet");
        if (!root.installed)
            return "Remote desktop unavailable — " + (RemoteDesktopService.unavailableReason || "Sunshine is not installed");
        if (root.visualState === "stale")
            return "Remote desktop state may be out of date — " + (RemoteDesktopService.watchError || "the host event watch is not running");
        if (root.hostUp) {
            if (!root.sessionKnown)
                return "Remote desktop is up — whether anyone is connected could not be checked: " + (RemoteDesktopService.sessionError || "the host journal could not be read");
            if (root.captureFallback)
                return "Remote desktop is up, but capturing a real monitor — " + RemoteDesktopService.outputName + " is missing";
            if (root.outputUnknown)
                return "Remote desktop is up — whether it is capturing " + RemoteDesktopService.outputName + " could not be checked";
            return "Remote desktop is up, nobody connected";
        }
        return "Remote desktop is off — click to open, toggle inside to start";
    }

    function sessionDetail() {
        const parts = [];
        if (RemoteDesktopService.sessionCodec)
            parts.push(RemoteDesktopService.sessionCodec);
        if (RemoteDesktopService.sessionBitrateBps > 0)
            parts.push(Math.round(RemoteDesktopService.sessionBitrateBps / 1000) + " kbps");
        if (RemoteDesktopService.sessionColorDepth)
            parts.push(RemoteDesktopService.sessionColorDepth);
        return parts.join(" · ");
    }

    Ref {
        service: RemoteDesktopService
    }

    // Starting the host creates a virtual output and opens a listening port, so
    // it is never reachable by a pointer crossing the bar. The pill opens the
    // popout; the toggle inside it is the only way to change state.
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

    // ============================ PILL ============================
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                id: pillIcon
                name: root.stateIcon
                size: root.iconSize
                color: root.pillIconColor
                filled: root.visualState === "streaming"
                // Dimmed reads as "present but not operable"; the popout still
                // explains why rather than doing nothing.
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

    // ============================ POPOUT ============================
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

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // ---- Host card + start/stop ----
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
                                    if (root.hostUp) {
                                        if (root.outputUnknown)
                                            return "capture target could not be checked";
                                        return RemoteDesktopService.outputPresent ? ("capturing " + RemoteDesktopService.outputName) : "";
                                    }
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
                            // An unknown host state has no true position to
                            // show, so the control is inert rather than
                            // offering to "start" something that may be up.
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

                // ---- Capture is falling back to a real monitor ----
                //
                // The whole reason the lifecycle lives in the helper. If this
                // ever shows, the host is streaming a screen the user is
                // actually looking at, and nothing else in the system says so.
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

                // ---- The state on screen may be out of date ----
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

                // ---- Live session ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    // Only while confirmed. The cached fields are cleared when
                    // the watch dies, so this would render an empty card;
                    // hiding it says "unknown" more honestly than blank rows.
                    visible: root.streaming && root.sessionKnown

                    StyledText {
                        text: "Session"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: [
                            { label: "Clients", value: String(RemoteDesktopService.sessionCount) },
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

                // ---- Web UI ----
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

                // ---- Paired devices ----
                //
                // PAIRED, not connected. Sunshine's journal does not say which
                // client a session belongs to, so naming one here would be a
                // guess dressed as a fact; the heading says which it is.
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: RemoteDesktopService.pairedClients.length > 0 || !RemoteDesktopService.pairedClientsKnown

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
