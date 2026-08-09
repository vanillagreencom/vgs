import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string pillMode: pluginData.pillMode || "status" // icon | status | count | tailnet

    property bool loaded: TailscaleService.stateInitialized
    property string backendState: TailscaleService.backendState
    property bool connected: TailscaleService.connected
    property bool connecting: false
    property string tailnetName: TailscaleService.tailnetName
    property string magicDnsSuffix: TailscaleService.magicDnsSuffix
    property var selfNode: TailscaleService.selfNode
    property var peers: TailscaleService.peers || []
    property var healthWarnings: TailscaleService.healthWarnings || []
    property bool acceptRoutes: TailscaleService.acceptRoutes
    property bool exitNodeAllowLan: TailscaleService.exitNodeAllowLanAccess
    property string authUrl: TailscaleService.authUrl

    readonly property var exitNodeOptions: TailscaleService.exitNodeOptions || []
    readonly property var currentExitNode: {
        return TailscaleService.currentExitNode;
    }
    readonly property int onlinePeerCount: TailscaleService.onlinePeerCount
    readonly property bool hasHealthIssue: root.connected && root.healthWarnings.length > 0

    Ref {
        service: TailscaleService
    }

    // ---- Derived pill presentation ----
    // tailscaled is still coming up. Reported honestly rather than as "Off":
    // the two look identical to the daemon-is-disabled case but mean opposite
    // things, and on a cold boot this is the state the shell sees first.
    readonly property bool starting: TailscaleService.starting
    // No answer from the backend yet. Also not "Off".
    readonly property bool awaiting: TailscaleService.awaitingFirstState
    // Had an answer, but it belongs to a connection that has since dropped, so
    // it says nothing about the backend we have now. Also not "Off".
    readonly property bool reacquiring: TailscaleService.reacquiring
    // Neither the daemon's state nor the connection is currently known.
    readonly property bool unknown: root.awaiting || root.reacquiring

    function stateShort() {
        if (root.connecting)
            return "…";
        if (root.unknown)
            return "…";
        if (root.starting)
            return "Starting";
        switch (root.backendState) {
        case "Running":
            return "On";
        case "NeedsLogin":
            return "Login";
        case "Stopped":
            return "Off";
        default:
            return root.loaded ? "Off" : "…";
        }
    }

    function pillIcon() {
        if (root.hasHealthIssue)
            return "warning";
        if (root.starting || root.unknown)
            return "pending";
        switch (root.backendState) {
        case "Running":
            return "router";
        case "NeedsLogin":
            return "vpn_key";
        default:
            return "vpn_key_off";
        }
    }

    // State color for the pill's *text*. Bar icons stay a single consistent
    // color; the icon glyph itself already changes with backend state.
    readonly property color pillColor: {
        if (root.hasHealthIssue)
            return Theme.error;
        if (root.connected)
            return Theme.primary;
        if (root.backendState === "NeedsLogin")
            return Theme.warning;
        return Theme.surfaceVariantText;
    }

    function pillText() {
        switch (root.pillMode) {
        case "icon":
            return "";
        case "count":
            return root.connected ? String(root.onlinePeerCount) : root.stateShort();
        case "tailnet":
            if (root.connected && root.tailnetName.length > 0)
                return root.tailnetName.split(".")[0];
            return root.stateShort();
        default:
            return root.stateShort();
        }
    }

    // ---- Helpers ----
    function selfIps() {
        if (!root.selfNode)
            return [];
        const ips = [];
        if (root.selfNode.tailscaleIp)
            ips.push(root.selfNode.tailscaleIp);
        if (root.selfNode.tailscaleIpv6)
            ips.push(root.selfNode.tailscaleIpv6);
        return ips;
    }

    // This device's full MagicDNS name (e.g. cachy.tail55311a.ts.net),
    // falling back to the tailnet suffix when the DNS name is unavailable.
    function selfMagicName() {
        if (root.selfNode && root.selfNode.dnsName && root.selfNode.dnsName.length > 0)
            return root.selfNode.dnsName.replace(/\.$/, "");
        return root.magicDnsSuffix;
    }

    function relTime(iso) {
        return TimeUtils.agoFromIso(iso);
    }

    function refresh() {
        TailscaleService.refresh(null);
    }

    // ---- Actions ----
    function connectTailscale() {
        root.connecting = true;
        root.authUrl = "";
        TailscaleService.connectTailscale(response => {
            root.connecting = false;
            if (response && response.result && response.result.authUrl)
                Quickshell.execDetached(["xdg-open", response.result.authUrl]);
            if (response && response.error)
                ToastService.showError("Tailscale action failed", response.error);
        });
    }

    function disconnectTailscale() {
        TailscaleService.disconnectTailscale(null);
    }

    function maybeOpenAuth(line) {
        const m = (line || "").match(/https?:\/\/[^\s]+/);
        if (m && m[0] && m[0].indexOf("login") !== -1) {
            root.authUrl = m[0];
            Quickshell.execDetached(["xdg-open", m[0]]);
        }
    }

    function setExitNode(value) {
        TailscaleService.setExitNode(value || "", null);
    }

    function setAcceptRoutes(enabled) {
        TailscaleService.setAcceptRoutes(enabled, null);
    }

    function setExitNodeLan(enabled) {
        TailscaleService.setAllowLanAccess(enabled, null);
    }

    function copyText(t) {
        if (t && t.length > 0)
            Quickshell.execDetached([Paths.vshellCli, "cl", "copy", t]);
    }

    // ============================ PILL ============================
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: root.pillIcon()
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: root.pillIcon()
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ============================ POPOUT ============================
    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Tailscale"
            detailsText: root.awaiting ? "Checking…" : (root.reacquiring ? "Reconnecting…" : (root.connected ? (root.tailnetName || "Connected") : (root.starting ? "Starting…" : (root.backendState === "NeedsLogin" ? "Needs login" : "Disconnected"))))
            showCloseButton: true

            // PluginPopout assigns itself here when it loads this content.
            property var parentPopout: null

            // Opening the popout is the moment the user is looking, so re-read
            // rather than showing whatever the last push left behind. Both
            // hooks are needed: onCompleted covers the first open, the
            // Connections cover every later one if the loader is kept alive.
            Component.onCompleted: TailscaleService.refreshStatus()

            Connections {
                target: parentPopout
                enabled: parentPopout !== null
                function onShouldBeVisibleChanged() {
                    if (parentPopout.shouldBeVisible)
                        TailscaleService.refreshStatus();
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // ---- Connection card + master switch ----
                StyledRect {
                    width: parent.width
                    height: connRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    RowLayout {
                        id: connRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: root.pillIcon()
                            size: Theme.iconSize
                            color: root.pillColor
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Column {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 1

                            StyledText {
                                text: root.connecting ? "Connecting…" : (root.awaiting ? "Checking…" : (root.reacquiring ? "Reconnecting…" : (root.connected ? "Connected" : (root.starting ? "Starting…" : (root.backendState === "NeedsLogin" ? "Not logged in" : "Disconnected")))))
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                visible: text.length > 0
                                text: root.awaiting ? "Reading status…" : (root.reacquiring ? "Lost contact with the VGS backend; retrying" : (root.connected ? (root.tailnetName || "") : (root.starting ? "tailscaled is still coming up" : (root.backendState === "NeedsLogin" ? "Sign in to connect" : "tailscaled stopped"))))
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                width: parent.width
                                elide: Text.ElideRight
                            }
                        }

                        VgsToggle {
                            id: connToggle
                            Layout.alignment: Qt.AlignVCenter
                            hideText: true
                            checked: root.connected
                            enabled: !root.connecting
                            onToggled: want => {
                                if (want)
                                    root.connectTailscale();
                                else
                                    root.disconnectTailscale();
                            }
                        }
                    }
                }

                // ---- Needs-login hint + explicit sign-in button ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: root.backendState === "NeedsLogin" || root.backendState === "Stopped" || root.starting || root.unknown

                    StyledText {
                        width: parent.width
                        text: root.backendState === "NeedsLogin" ? "This device isn't signed in to a tailnet yet. Connect to open the Tailscale login page in your browser." : (root.backendState === "Stopped" ? "Tailscale is installed and the daemon is running, but networking is turned off." : (root.starting ? "tailscaled is still starting up. This resolves on its own once it reaches the tailnet." : (root.reacquiring ? "The VGS backend connection dropped. Reconnecting; the status below is from before the drop." : "Reading Tailscale status…")))
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        lineHeight: 1.2
                        lineHeightMode: Text.ProportionalHeight
                    }

                    VgsButton {
                        visible: root.backendState === "NeedsLogin" || root.backendState === "Stopped"
                        text: root.connecting ? "Connecting…" : (root.backendState === "NeedsLogin" ? "Sign in & connect" : "Connect")
                        iconName: "login"
                        enabled: !root.connecting
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        onClicked: root.connectTailscale()
                    }
                }

                // ---- This device card ----
                StyledRect {
                    width: parent.width
                    visible: root.connected && root.selfNode !== null
                    height: selfCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: selfCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        Row {
                            spacing: Theme.spacingXS
                            width: parent.width

                            VgsIcon {
                                name: "computer"
                                size: Theme.iconSizeSmall
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: root.selfNode ? root.selfNode.hostname : ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: "This device"
                                font.pixelSize: 10
                                color: Theme.primary
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        // Tailscale IPs (copyable)
                        Repeater {
                            model: root.selfIps()

                            RowLayout {
                                width: selfCol.width
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: "lan"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceVariantText
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                StyledText {
                                    text: modelData
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextMedium
                                    Layout.fillWidth: true
                                }

                                VgsActionButton {
                                    iconName: "content_copy"
                                    buttonSize: 20
                                    iconSize: 11
                                    iconColor: Theme.surfaceVariantText
                                    tooltipText: "Copy"
                                    onClicked: root.copyText(modelData)
                                }
                            }
                        }

                        RowLayout {
                            visible: root.selfMagicName().length > 0
                            width: selfCol.width
                            spacing: Theme.spacingXS

                            VgsIcon {
                                name: "dns"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: root.selfMagicName()
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceTextMedium
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            VgsActionButton {
                                iconName: "content_copy"
                                buttonSize: 20
                                iconSize: 11
                                iconColor: Theme.surfaceVariantText
                                tooltipText: "Copy MagicDNS name"
                                onClicked: root.copyText(root.selfMagicName())
                            }
                        }

                        StyledText {
                            width: parent.width
                            text: root.currentExitNode ? ("Exit node: " + root.currentExitNode.hostname) : "Exit node: none"
                            font.pixelSize: 10
                            color: root.currentExitNode ? Theme.primary : Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }
                }

                // ---- Exit node selector ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.connected && root.exitNodeOptions.length > 0

                    StyledText {
                        text: "Exit node"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                    }

                    // "None" option
                    StyledRect {
                        id: noneRow
                        property bool active: root.currentExitNode === null
                        width: parent.width
                        height: 32
                        radius: Theme.cornerRadius
                        color: active ? Theme.primaryHover : (noneArea.containsMouse ? Theme.primaryHoverLight : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            spacing: Theme.spacingS

                            VgsIcon {
                                name: "block"
                                size: Theme.iconSizeSmall
                                color: noneRow.active ? Theme.primary : Theme.surfaceVariantText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: "None"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: noneRow.active ? Font.Medium : Font.Normal
                                color: noneRow.active ? Theme.primary : Theme.surfaceText
                                Layout.fillWidth: true
                            }
                        }

                        MouseArea {
                            id: noneArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setExitNode("")
                        }
                    }

                    Repeater {
                        model: root.exitNodeOptions

                        StyledRect {
                            id: exitRow
                            required property var modelData
                            width: parent.width
                            height: 32
                            radius: Theme.cornerRadius
                            color: modelData.exitNode ? Theme.primaryHover : (exitArea.containsMouse ? Theme.primaryHoverLight : "transparent")

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                spacing: Theme.spacingS

                                Rectangle {
                                    width: 8
                                    height: 8
                                    radius: 4
                                    color: modelData.online ? "#4caf50" : Theme.surfaceVariantText
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                StyledText {
                                    text: modelData.hostname
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: modelData.exitNode ? Font.Medium : Font.Normal
                                    color: modelData.exitNode ? Theme.primary : Theme.surfaceText
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }

                                VgsIcon {
                                    visible: modelData.exitNode
                                    name: "check"
                                    size: Theme.iconSizeSmall
                                    color: Theme.primary
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }

                            MouseArea {
                                id: exitArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setExitNode(TailscaleService.exitNodeTarget(modelData))
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        visible: root.currentExitNode !== null
                        height: lanToggle.height
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        VgsToggle {
                            id: lanToggle
                            width: parent.width
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Allow LAN access"
                            description: "Reach local devices while using an exit node"
                            checked: root.exitNodeAllowLan
                            onToggled: v => root.setExitNodeLan(v)
                        }
                    }
                }

                // ---- Accept routes toggle ----
                StyledRect {
                    width: parent.width
                    visible: root.connected
                    height: acceptToggle.height
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    VgsToggle {
                        id: acceptToggle
                        width: parent.width
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Accept subnet routes"
                        description: "Use routes advertised by other nodes"
                        checked: root.acceptRoutes
                        onToggled: v => root.setAcceptRoutes(v)
                    }
                }

                // ---- Health warnings ----
                StyledRect {
                    width: parent.width
                    visible: root.hasHealthIssue
                    height: healthCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.error, 0.12)

                    Column {
                        id: healthCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        Row {
                            spacing: Theme.spacingXS

                            VgsIcon {
                                name: "warning"
                                size: Theme.iconSizeSmall
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: "Health warnings"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Repeater {
                            model: root.healthWarnings

                            StyledText {
                                required property var modelData
                                width: healthCol.width
                                text: "• " + modelData
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                wrapMode: Text.WordWrap
                                lineHeight: 1.2
                                lineHeightMode: Text.ProportionalHeight
                            }
                        }
                    }
                }

                // ---- Devices list ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.connected

                    // Extra separation so the Devices section breathes below the
                    // connection controls above it.
                    Item {
                        width: parent.width
                        height: Theme.spacingS
                    }

                    RowLayout {
                        width: parent.width

                        StyledText {
                            text: "Devices"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Bold
                            color: Theme.surfaceVariantText
                            Layout.fillWidth: true
                        }

                        StyledText {
                            text: root.onlinePeerCount + " online · " + (root.peers ? root.peers.length : 0)
                            font.pixelSize: 10
                            color: Theme.surfaceVariantText
                        }
                    }

                    StyledText {
                        visible: !root.peers || root.peers.length === 0
                        width: parent.width
                        text: "No other devices in this tailnet."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    VgsFlickable {
                        width: parent.width
                        height: Math.min(contentHeight, 240)
                        contentHeight: peerCol.implicitHeight
                        clip: true
                        visible: root.peers && root.peers.length > 0

                        Column {
                            id: peerCol
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.peers

                                StyledRect {
                                    required property var modelData
                                    width: peerCol.width
                                    height: cardCol.implicitHeight + Theme.spacingM * 2
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh

                                    Column {
                                        id: cardCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: Theme.spacingM
                                        spacing: 2

                                        RowLayout {
                                            width: parent.width
                                            spacing: Theme.spacingS

                                            Rectangle {
                                                width: 8
                                                height: 8
                                                radius: 4
                                                color: modelData.online ? "#4caf50" : Theme.surfaceVariantText
                                                Layout.alignment: Qt.AlignVCenter
                                            }

                                            StyledText {
                                                text: modelData.hostname
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                            }

                                            VgsIcon {
                                                visible: modelData.exitNode
                                                name: "vpn_lock"
                                                size: Theme.iconSizeSmall
                                                color: Theme.primary
                                                Layout.alignment: Qt.AlignVCenter
                                            }
                                        }

                                        RowLayout {
                                            width: parent.width
                                            spacing: Theme.spacingXS

                                            StyledText {
                                                text: modelData.tailscaleIp || ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceTextMedium
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                            }

                                            VgsActionButton {
                                                visible: (modelData.tailscaleIp || "").length > 0
                                                iconName: "content_copy"
                                                buttonSize: 20
                                                iconSize: 11
                                                iconColor: Theme.surfaceVariantText
                                                tooltipText: "Copy"
                                                onClicked: root.copyText(modelData.tailscaleIp)
                                            }
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: {
                                                const parts = [];
                                                if (modelData.os)
                                                    parts.push(modelData.os);
                                                if (modelData.online)
                                                    parts.push(modelData.relay ? ("relay: " + modelData.relay) : "direct");
                                                else {
                                                    const ls = root.relTime(modelData.lastSeen);
                                                    if (ls)
                                                        parts.push("last seen " + ls);
                                                }
                                                if (modelData.exitNodeOption)
                                                    parts.push("exit node");
                                                return parts.join(" · ");
                                            }
                                            font.pixelSize: 10
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
